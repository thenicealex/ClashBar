import Foundation
import Testing
@testable import ClashBar

struct ChainProxyLogRedactorTests {
    @Test func hidesKnownCredentialsAndPreservesConnectionDiagnostics() {
        var redactor = ChainProxyLogRedactor()
        redactor.include(yaml: """
        type: socks5
        server: exit.example.com
        port: 443
        username: private-user
        password: 'p@ss:word "quoted"'
        plugin-opts: {token: nested-token}
        auth-str: private-auth
        """)
        let message = "dial Chain Proxy exit.example.com:443: private-user p@ss:word \"quoted\" nested-token private-auth i/o timeout"
        let sanitized = redactor.redact(message)
        #expect(!sanitized.contains("private-user"))
        #expect(!sanitized.contains("p@ss"))
        #expect(!sanitized.contains("nested-token"))
        #expect(!sanitized.contains("private-auth"))
        #expect(sanitized.contains("exit.example.com:443"))
        #expect(sanitized.contains("i/o timeout"))
        let encoded = redactor.redact(#"{"details":"p@ss:word \"quoted\"","status":502}"#)
        #expect(!encoded.contains("p@ss"))
        #expect(encoded.contains("502"))
    }

    @Test func masksUnknownCredentialFieldsURLsAndAuthorization() {
        let redactor = ChainProxyLogRedactor()
        let message = #"password: secret-value uuid=private-uuid {"token":"escaped\"secret"} https://login:pass@host:443 failed Proxy-Authorization: Basic cHJpdmF0ZQ=="#
        let sanitized = redactor.redact(message)
        for value in ["secret-value", "private-uuid", "escaped", "login:pass", "cHJpdmF0ZQ=="] {
            #expect(!sanitized.contains(value))
        }
        #expect(sanitized.contains("host:443 failed"))
    }

    @Test func shortCredentialsDoNotDestroyUnrelatedWordsAndOldValuesStayRedacted() {
        var redactor = ChainProxyLogRedactor()
        redactor.include(yaml: "username: a\npassword: 12\n")
        redactor.include(yaml: "password: replacement-secret\n")
        #expect(redactor.redact("stage validate: a 12 replacement-secret") == "stage validate: [redacted] [redacted] [redacted]")
        #expect(redactor.redact("TCP dial: i/o timeout") == "TCP dial: i/o timeout")
    }
}
