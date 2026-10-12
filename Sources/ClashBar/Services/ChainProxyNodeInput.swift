import Foundation
import Yams

struct ChainProxyNodeForm {
    var type = "socks5"
    var server = ""
    var port = "1080"
    var username = ""
    var password = ""
    var tls = false

    init() {}

    init(yaml: String) throws {
        guard let proxy = try Yams.load(yaml: yaml) as? [String: Any],
              let type = proxy["type"] as? String, ["socks5", "http"].contains(type)
        else { throw ChainProxyConfigError.unsupportedNodeForm }
        self.type = type
        self.server = proxy["server"] as? String ?? ""
        self.port = proxy["port"].map { String(describing: $0) } ?? ""
        self.username = proxy["username"] as? String ?? ""
        self.password = proxy["password"] as? String ?? ""
        self.tls = proxy["tls"] as? Bool ?? false
    }

    func yaml(preserving source: String) throws -> String {
        var proxy = try Yams.load(yaml: source) as? [String: Any] ?? [:]
        // Patch only form fields. Protocol-specific and unknown parameters stay intact.
        proxy["type"] = self.type
        proxy["server"] = self.server.trimmingCharacters(in: .whitespacesAndNewlines)
        if proxy["port"].map({ String(describing: $0) }) != self.port {
            if let port = Int(self.port) { proxy["port"] = port } else { proxy["port"] = self.port }
        }
        for (key, value) in [("username", self.username), ("password", self.password)] {
            if value != (proxy[key] as? String ?? "") {
                proxy[key] = value.isEmpty ? nil : value
            }
        }
        if self.tls != (proxy["tls"] as? Bool ?? false) { proxy["tls"] = self.tls }
        return try Yams.dump(object: proxy, allowUnicode: true, sortKeys: true)
    }
}

enum ChainProxyNodeLink {
    static func parse(_ input: String) throws -> ChainProxyNode {
        do {
            let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.contains(where: { $0.isWhitespace }),
                  let schemeEnd = input.range(of: "://")
            else { throw ChainProxyConfigError.invalidNodeLink }
            let scheme = input[..<schemeEnd.lowerBound].lowercased()
            guard ["ss", "socks5", "http", "https"].contains(scheme) else {
                throw ChainProxyConfigError.invalidNodeLink
            }
            let parts = input[schemeEnd.upperBound...].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            var address = String(parts[0])
            var ssCredentials: String?
            if scheme == "ss" {
                if let at = address.lastIndex(of: "@") {
                    guard let userInfo = String(address[..<at]).removingPercentEncoding else {
                        throw ChainProxyConfigError.invalidNodeLink
                    }
                    ssCredentials = userInfo.contains(":") ? userInfo : try self.decode(userInfo)
                    address = String(address[address.index(after: at)...])
                } else {
                    let decoded = try self.decode(address)
                    guard let at = decoded.lastIndex(of: "@") else {
                        throw ChainProxyConfigError.invalidNodeLink
                    }
                    ssCredentials = String(decoded[..<at])
                    address = String(decoded[decoded.index(after: at)...])
                }
            }
            guard let components = URLComponents(string: "\(scheme)://\(address)"),
                  let host = components.host, !host.isEmpty,
                  components.rangeOfPort == nil || components.port != nil,
                  components.query == nil, ["", "/"].contains(components.path)
            else { throw ChainProxyConfigError.invalidNodeLink }
            let port = components.port ?? (scheme == "http" ? 80 : scheme == "https" ? 443 : 0)
            var proxy: [String: Any] = [
                "type": scheme == "ss" ? "ss" : scheme == "socks5" ? "socks5" : "http",
                "server": host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host,
                "port": port,
            ]
            if scheme == "ss" {
                guard let credentials = ssCredentials,
                      let colon = credentials.firstIndex(of: ":"), colon != credentials.startIndex
                else { throw ChainProxyConfigError.invalidNodeLink }
                proxy["cipher"] = String(credentials[..<colon])
                let password = String(credentials[credentials.index(after: colon)...])
                guard !password.isEmpty else { throw ChainProxyConfigError.invalidNodeLink }
                proxy["password"] = password
            } else {
                if let user = components.percentEncodedUser {
                    guard let decoded = user.removingPercentEncoding else {
                        throw ChainProxyConfigError.invalidNodeLink
                    }
                    proxy["username"] = decoded
                }
                if let password = components.percentEncodedPassword {
                    guard let decoded = password.removingPercentEncoding else {
                        throw ChainProxyConfigError.invalidNodeLink
                    }
                    proxy["password"] = decoded
                }
                if scheme == "https" { proxy["tls"] = true }
            }
            let tag = parts.count == 2 ? String(parts[1]) : ""
            guard let name = tag.removingPercentEncoding else { throw ChainProxyConfigError.invalidNodeLink }
            return try ChainProxyConfigService.makeNode(
                name: name.trimmedNonEmpty ?? host,
                yaml: Yams.dump(object: proxy, allowUnicode: true, sortKeys: true))
        } catch {
            // Never include a pasted link or its credentials in diagnostics.
            throw ChainProxyConfigError.invalidNodeLink
        }
    }

    private static func decode(_ input: String) throws -> String {
        var base64 = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let decoded = String(data: data, encoding: .utf8) else {
            throw ChainProxyConfigError.invalidNodeLink
        }
        return decoded
    }
}
