import Foundation
import Testing
import Yams
@testable import ClashBar

struct ChainProxyNodeInputTests {
    @Test(arguments: ["socks5", "http"])
    func formEditsPreserveIDAndCompleteParameters(type: String) throws {
        let original = try ChainProxyConfigService.makeNode(id: "original", name: "Node", yaml: """
        type: \(type)
        server: old.example.com
        port: '1080'
        username: user
        password: 'secret: #value'
        tls: true
        skip-cert-verify: false
        sni: tls.example.com
        udp: true
        headers: {X-Custom: [one, two]}
        custom: {nested: {flag: true, value: 42}}
        """)
        let source = try #require(try Yams.load(yaml: original.yaml) as? [String: Any])
        var form = try ChainProxyNodeForm(yaml: original.yaml)
        let unchanged = try #require(try Yams.load(yaml: form.yaml(preserving: original.yaml)) as? [String: Any])
        #expect(NSDictionary(dictionary: source).isEqual(to: unchanged))
        form.server = "new.example.com"
        let edited = try ChainProxyConfigService.makeNode(
            id: original.id, name: "Renamed", yaml: form.yaml(preserving: original.yaml))
        let actual = try #require(try Yams.load(yaml: edited.yaml) as? [String: Any])
        var expected = source
        expected["server"] = "new.example.com"
        expected["name"] = "Renamed"
        #expect(edited.id == original.id)
        #expect(NSDictionary(dictionary: expected).isEqual(to: actual))
        let roundTrip = try ChainProxyNodeForm(yaml: edited.yaml)
        let result = try #require(try Yams.load(yaml: roundTrip.yaml(preserving: edited.yaml)) as? [String: Any])
        #expect(NSDictionary(dictionary: actual).isEqual(to: result))
        form.username = ""
        form.password = ""
        form.tls = false
        form.port = "8080"
        let cleared = try #require(try Yams.load(yaml: form.yaml(preserving: original.yaml)) as? [String: Any])
        #expect(cleared["username"] == nil)
        #expect(cleared["password"] == nil)
        #expect(cleared["tls"] as? Bool == false)
        #expect(cleared["port"] as? Int == 8080)
        #expect(cleared["custom"] as? NSDictionary == source["custom"] as? NSDictionary)
    }

    @Test func newFormValidatesAndUnsupportedProtocolsRequireYAML() throws {
        var form = ChainProxyNodeForm()
        form.server = "localhost"
        let yaml = try form.yaml(preserving: "{}")
        let node = try ChainProxyConfigService.makeNode(name: "Local", yaml: yaml)
        #expect(node.name == "Local")
        form.port = "not a port"
        let invalid = try form.yaml(preserving: yaml)
        #expect(throws: ChainProxyConfigError.invalidNodeConfig) {
            try ChainProxyConfigService.makeNode(name: "Local", yaml: invalid)
        }
        #expect(throws: ChainProxyConfigError.unsupportedNodeForm) {
            try ChainProxyNodeForm(yaml: "type: ss\nserver: localhost\nport: 443\n")
        }
    }

    @Test func importsProxyLinksWithEscapedCredentialsAndIPv6() throws {
        let node = try ChainProxyNodeLink.parse("socks5://a%40b:p%3Ass%2B%25@[2001:db8::1]:1080#%E8%8A%82%E7%82%B9")
        let proxy = try #require(try Yams.load(yaml: node.yaml) as? [String: Any])
        #expect(node.name == "节点")
        #expect(proxy["server"] as? String == "2001:db8::1")
        #expect(proxy["username"] as? String == "a@b")
        #expect(proxy["password"] as? String == "p:ss+%")
        #expect(proxy["port"] as? Int == 1080)
    }

    @Test(arguments: ["http", "https"], [
        "0", "65536", "-1", "abc", "9223372036854775808", "999999999999999999999999999999",
    ])
    func httpLinksRejectExplicitInvalidPorts(scheme: String, port: String) {
        for host in ["proxy.example.com", "[2001:db8::1]"] {
            #expect(throws: ChainProxyConfigError.invalidNodeLink) {
                try ChainProxyNodeLink.parse("\(scheme)://\(host):\(port)#Web")
            }
        }
    }

    @Test(arguments: ["http", "https"], ["", ":80", ":8443"])
    func httpLinksDefaultOnlyOmittedPorts(scheme: String, port: String) throws {
        for host in ["proxy.example.com", "[2001:db8::1]"] {
            let node = try ChainProxyNodeLink.parse("\(scheme)://user:p%3Ass@\(host)\(port)/#Web")
            let config = try #require(try Yams.load(yaml: node.yaml) as? [String: Any])
            let expectedPort = port.isEmpty ? (scheme == "http" ? 80 : 443) : Int(port.dropFirst())
            #expect(config["type"] as? String == "http")
            #expect(config["port"] as? Int == expectedPort)
            #expect(config["tls"] as? Bool == (scheme == "https" ? true : nil))
            #expect(config["username"] as? String == "user")
            #expect(config["password"] as? String == "p:ss")
        }
    }

    @Test func importsShadowsocksSIP002AndLegacyFormats() throws {
        let credentials = "aes-256-gcm:päss:word/@%+"
        let base64 = Data(credentials.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let padded = Data(credentials.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "%3D")
        let legacy = Data("\(credentials)@ss.example.com:8388".utf8).base64EncodedString()
        let links = [
            "ss://\(base64)@ss.example.com:8388/#SS",
            "ss://\(padded)@ss.example.com:8388#SS",
            "ss://aes-256-gcm:p%C3%A4ss%3Aword%2F%40%25%2B@ss.example.com:8388#SS",
            "ss://\(legacy)#SS",
        ]
        for link in links {
            let node = try ChainProxyNodeLink.parse(link)
            let proxy = try #require(try Yams.load(yaml: node.yaml) as? [String: Any])
            #expect(node.name == "SS")
            #expect(proxy["cipher"] as? String == "aes-256-gcm")
            #expect(proxy["password"] as? String == "päss:word/@%+")
            #expect(proxy["server"] as? String == "ss.example.com")
            #expect(proxy["port"] as? Int == 8388)
        }
    }

    @Test(arguments: [
        "socks5://host:0", "socks5://host", "http://host/subscription",
        "vless://id@host:443", "ss://invalid@host:443", "ss://aes-256-gcm:@host:443",
        "ss://aes-256-gcm:pass@host:443/?plugin=obfs-local", "https://host?udp=true",
        "http://host:80\nsocks5://host:1080",
        "http://host:80#%GG",
    ])
    func rejectsInvalidOrUnsupportedLinks(link: String) {
        #expect(throws: ChainProxyConfigError.invalidNodeLink) { try ChainProxyNodeLink.parse(link) }
    }

    @Test func importedNodePersistsWithoutAirportOrLinkSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let node = try ChainProxyNodeLink.parse("https://user:pass@proxy.example.com:8443#Independent")
        try ChainProxyConfigService.writeNodes([node], workingDirectory: root)
        let restored = try ChainProxyConfigService.readNodes(workingDirectory: root, settings: nil)
        #expect(restored == [node])
    }
}
