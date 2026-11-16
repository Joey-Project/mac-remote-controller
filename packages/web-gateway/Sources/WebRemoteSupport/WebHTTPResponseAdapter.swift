import NIOCore
import NIOHTTP1

/// Bridge the Sendable async-channel body to NIO's outbound HTTP representation.
final class WebHTTPResponseAdapter: ChannelOutboundHandler {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch unwrapOutboundIn(data) {
        case .head(let head): context.write(wrapOutboundOut(.head(head)), promise: promise)
        case .body(let body):
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: promise)
        case .end(let trailers): context.write(wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}
