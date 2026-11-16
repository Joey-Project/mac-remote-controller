import Testing
@testable import WebRemoteSupport

@Test func endpointRequiresExplicitPrivateLANBinding() throws {
    let endpoint = try WebEndpoint(
        hostname: "remote.example.com", port: 47_625, bindAddress: "192.168.1.10",
        certificateChain: "/private/certificate.pem", privateKey: "/private/key.pem")
    #expect(endpoint.origin == "https://remote.example.com:47625")
    for address in ["0.0.0.0", "127.0.0.1", "169.254.1.2", "8.8.8.8", "192.168.001.10", "::"] {
        #expect(!WebEndpoint.isPrivateIPv4(address))
    }
}

@Test func hostnameCannotIntroduceAnotherURLAuthority() {
    for hostname in [
        "remote.example.com/path", "user@remote.example.com", "remote.example.com:443",
        "remote.local", "remote.localhost", "192.168.1.10", ".example.com", "remote.example.com."
    ] {
        #expect(!WebEndpoint.isHostname(hostname))
    }
    #expect(WebEndpoint.isHostname("remote.local.example.com"))
}
