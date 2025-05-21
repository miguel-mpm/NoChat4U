import Vapor

public func route(_ app: Application) async throws {
    app.get("customConfig", "**") { req -> ClientResponse in
            return try await handleConfigRequest(request: req, app: app)
        }
}

private func handleConfigRequest(request: Request, app: Application) async throws -> ClientResponse {
    let configServerURL = "https://clientconfig.rpg.riotgames.com"
    let newPath = request.url.path.replacingOccurrences(of: "/customConfig", with: "")
    let query = request.url.query.map { "?\($0)" } ?? ""
    let url = URI(string: configServerURL + newPath + query)
    

    print("Forwarding config request to \(url)")

    let client = app.client

    let response = try await client.get(url) { req in
        ["User-Agent", "X-Riot-Entitlements-JWT", "Authorization"].forEach {
            req.headers.add(name: $0, value: request.headers.first(name: $0) ?? "undefined")
        }
    }

    guard let responseBody = response.body,
          let jsonData = responseBody.getData(at: 0, length: responseBody.readableBytes) else {
        throw Abort(.internalServerError, reason: "Failed to retrieve response body.")
    }

    // Check for "chat.affinity.enabled"
    guard let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any],
          let chatAffinityEnabled = jsonObject["chat.affinity.enabled"] as? Bool, chatAffinityEnabled else {
        return ClientResponse(status: response.status, body: .init(string: String(data: jsonData, encoding: .utf8) ?? ""))
    }

    let geoPasURL = "https://riot-geo.pas.si.riotgames.com/pas/v1/service/chat"
    let authorizationHeader = request.headers.first(name: "Authorization") ?? "undefined"

    // Make a request to the geo pas URL
    let geoResponse = try await client.get(URI(string: geoPasURL)) { req in
        req.headers.add(name: "Authorization", value: authorizationHeader)
    }

    // Extract the JWT token from the geoResponse
    guard let geoResponseBody = geoResponse.body,
          let geoJsonData = geoResponseBody.getData(at: 0, length: geoResponseBody.readableBytes),
          let geoToken = String(data: geoJsonData, encoding: .utf8) else {
        throw Abort(.internalServerError, reason: "Failed to retrieve geo response body.")
    }

    // Decode the JWT and get the affinity
    guard let affinity = decodeJWTAndGetAffinity(jwtToken: geoToken) else {
        print("Affinity not found in JWT payload.")
        return ClientResponse(status: response.status, body: .init(string: String(data: jsonData, encoding: .utf8) ?? ""))
    }

    var riotChatHost = jsonObject["chat.host"] as? String

    // Look for "chat.affinities" in the original config response
    let chatAffinities = jsonObject["chat.affinities"] as? [String: String]

    riotChatHost = chatAffinities?[affinity]

    // Store the original chat server information
    if let originalHost = riotChatHost,
       let originalPort = jsonObject["chat.port"] as? Int {
        SharedState.shared.setOriginalChatServer(host: originalHost, port: originalPort)
        print("Original host: \(originalHost)")
        print("Original port: \(originalPort)")

    }

    // Replace "chat.host" and "chat.port" in the original config response
    var modifiedJsonObject = jsonObject
    modifiedJsonObject["chat.host"] = "127.0.0.1"
    modifiedJsonObject["chat.port"] = SharedState.shared.chatProxyPort ?? app.http.server.shared.localAddress?.port
    modifiedJsonObject["chat.allow_bad_cert.enabled"] = true
    
    // Create a new affinities object with all regions pointing to localhost
    var newAffinities: [String: String] = [:]
    if let originalAffinities = chatAffinities {
        for (region, _) in originalAffinities {
            newAffinities[region] = "127.0.0.1"
        }
    }
    modifiedJsonObject["chat.affinities"] = newAffinities

    //print("Modified json payload: \(modifiedJsonObject)")

    // Serialize the modified JSON object back to Data
    let modifiedJsonData = try JSONSerialization.data(withJSONObject: modifiedJsonObject, options: [])
    
    return ClientResponse(status: response.status, body: .init(data: modifiedJsonData))
}

private func decodeJWTAndGetAffinity(jwtToken: String) -> String? {
    let components = jwtToken.split(separator: ".")
    guard components.count == 3 else {
        print("Invalid JWT format.")
        return nil
    }

    let payloadBase64 = String(components[1])
    let padding = String(repeating: "=", count: (4 - payloadBase64.count % 4) % 4)
    let payloadData = Data(base64Encoded: payloadBase64 + padding)

    guard let jsonData = payloadData else {
        print("Failed to decode JWT payload.")
        return nil
    }

    do {
        if let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any],
           let affinity = jsonObject["affinity"] as? String {
            return affinity
        }
    } catch {
        print("Failed to deserialize JSON: \(error)")
    }

    return nil
}

