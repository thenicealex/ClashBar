import Foundation
import Yams

struct ChainProxyLogRedactor {
    private var secrets: Set<String> = []

    mutating func include(yaml: String) {
        guard let value = try? Yams.load(yaml: yaml) else { return }
        self.include(value)
    }

    private mutating func include(_ value: Any) {
        if let dictionary = value as? [String: Any] {
            for (key, value) in dictionary {
                if ["username", "password", "uuid", "secret", "token", "private-key", "psk",
                    "auth", "auth-str", "auth-string", "client-key", "client-secret"]
                    .contains(key.lowercased().replacingOccurrences(of: "_", with: "-")),
                   let secret = value as? String ?? (value as? NSNumber)?.stringValue, !secret.isEmpty
                {
                    self.secrets.insert(secret)
                    if let data = try? JSONEncoder().encode(secret), let encoded = String(data: data, encoding: .utf8) {
                        self.secrets.insert(String(encoded.dropFirst().dropLast()))
                    }
                    if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                        self.secrets.insert(encoded)
                    }
                }
                self.include(value)
            }
        } else if let array = value as? [Any] {
            for value in array { self.include(value) }
        }
    }

    func redact(_ message: String) -> String {
        var message = message
        for secret in self.secrets.sorted(by: { $0.count > $1.count }) {
            if secret.count >= 4 {
                message = message.replacingOccurrences(of: secret, with: "[redacted]")
            } else {
                let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: secret)
                    + "(?![\\p{L}\\p{N}_])"
                message = message.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
            }
        }
        message = message.replacingOccurrences(
            of: #"(?i)([a-z][a-z0-9+.-]*://)[^/\s]*@"#,
            with: "$1[redacted]@", options: .regularExpression)
        message = message.replacingOccurrences(
            of: #"(?i)(["']?(?:username|password|passwd|uuid|secret|token|private[-_]key|psk|auth(?:[-_](?:str|string))?|client[-_](?:key|secret))["']?\s*[:=]\s*)("(?:\\.|[^"\\])*"|'[^']*'|[^\s,;}\]]+)"#,
            with: "$1[redacted]", options: .regularExpression)
        message = message.replacingOccurrences(
            of: #"(?i)((?:Proxy-)?Authorization\s*[:=]\s*)(?:Basic|Bearer)\s+\S+"#,
            with: "$1[redacted]", options: .regularExpression)
        return message
    }
}
