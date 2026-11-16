import CryptoKit
import Darwin
import Foundation
import NIOSSL

struct WebTLSMaterial: Sendable {
    let context: NIOSSLContext
    let certificateFingerprint: String

    static func load(_ endpoint: WebEndpoint) throws -> Self {
        let chain = try read(endpoint.certificateChain, limit: 65_536, privateFile: false)
        let key = try read(endpoint.privateKey, limit: 16_384, privateFile: true)
        let certificates = try NIOSSLCertificate.fromPEMBytes(Array(chain))
        let privateKey = try NIOSSLPrivateKey(bytes: Array(key), format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(privateKey))
        configuration.minimumTLSVersion = .tlsv13
        configuration.applicationProtocols = ["http/1.1"]
        return Self(
            context: try NIOSSLContext(configuration: configuration),
            certificateFingerprint: SHA256.hash(data: chain).map { String(format: "%02x", $0) }
                .joined())
    }

    /// Validate the opened file's access policy, allowing Certbot's live symlinks.
    static func read(_ path: String, limit: Int, privateFile: Bool) throws -> Data {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let descriptor = open(canonical, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw WebTLSFileError.notFound }
            throw WebTLSFileError.unavailable
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_size > 0, metadata.st_size <= limit
        else { throw WebTLSFileError.unavailable }
        if privateFile {
            guard metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else {
                throw WebTLSFileError.insecurePrivateKey
            }
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try file.read(upToCount: limit + 1), data.count <= limit else {
            throw WebTLSFileError.unavailable
        }
        return data
    }
}

enum WebTLSFileError: Error { case notFound, unavailable, insecurePrivateKey }
