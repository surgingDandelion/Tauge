import Foundation
import NIOCore
import NIOSSH

/// Converts between raw ByteBuffers and SSHChannelData so a child channel can carry
/// an opaque byte stream (SFTP, terminal I/O, or a tunneled TCP connection).
public final class SSHChannelAdapter: ChannelDuplexHandler, @unchecked Sendable {
    public typealias InboundIn = SSHChannelData
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = SSHChannelData

    public var onData: (@Sendable (Data) -> Void)?
    public var onClose: (@Sendable (Error?) -> Void)?
    private var closed = false

    public init() {}

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        onData?(Data(buffer: buffer))
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        notifyClose(nil)
        context.fireChannelInactive()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        notifyClose(error)
        context.close(promise: nil)
    }

    private func notifyClose(_ error: Error?) {
        guard !closed else { return }
        closed = true
        onClose?(error)
    }
}

/// Pass-through adapter that lets another NIOSSHHandler ride on a forwarded channel.
///
/// A jump host is reached by opening a direct-tcpip channel and layering SSH on top of
/// it: inbound SSHChannelData has to become a plain byte stream (what NIOSSHHandler
/// decodes) and its outbound bytes have to be wrapped again. SSHChannelAdapter cannot
/// be used here because it consumes inbound data instead of forwarding it.
public final class SSHStreamAdapter: ChannelDuplexHandler, @unchecked Sendable {
    public typealias InboundIn = SSHChannelData
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = SSHChannelData

    public init() {}

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard channelData.type == .channel, case .byteBuffer(let buffer) = channelData.data else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

/// Byte-oriented transport over an SSH session channel, used by the SFTP client.
public final class SSHByteStreamTransport: SFTPTransport, @unchecked Sendable {
    private let channel: Channel
    private let adapter: SSHChannelAdapter
    private let lock = NSLock()
    private var buffer = Data()
    private var waiter: CheckedContinuation<Data?, Never>?
    private var closed = false
    private var terminalError: Error?

    public init(channel: Channel, adapter: SSHChannelAdapter) {
        self.channel = channel
        self.adapter = adapter
        adapter.onData = { [weak self] data in
            self?.deliver(data)
        }
        adapter.onClose = { [weak self] error in
            self?.closeStream(error)
        }
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.closeStream(nil)
        }
    }

    public func send(_ data: Data) {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { return }
        let buffer = channel.allocator.buffer(bytes: data)
        channel.writeAndFlush(buffer, promise: nil)
    }

    public func receive() async -> Data? {
        lock.lock()
        if !buffer.isEmpty {
            let chunk = buffer
            buffer.removeAll(keepingCapacity: true)
            lock.unlock()
            return chunk
        }
        if closed {
            lock.unlock()
            return nil
        }
        lock.unlock()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if !buffer.isEmpty {
                let chunk = buffer
                buffer.removeAll(keepingCapacity: true)
                lock.unlock()
                continuation.resume(returning: chunk)
                return
            }
            if closed {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    public func closeTransport() {
        channel.close(mode: .all, promise: nil)
        closeStream(nil)
    }

    private func deliver(_ data: Data) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: data)
            return
        }
        buffer.append(data)
        lock.unlock()
    }

    private func closeStream(_ error: Error?) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        terminalError = error
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: nil)
    }
}

final class CloseNotifier: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let handler: @Sendable (Error?) -> Void

    init(_ handler: @escaping @Sendable (Error?) -> Void) {
        self.handler = handler
    }

    func fire(_ error: Error?) {
        lock.lock()
        if fired {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        handler(error)
    }
}

/// A live interactive terminal session. It is either backed by an in-process
/// SSH channel or by a local `ssh` child process attached to a pseudo terminal.
public final class SSHTerminalSession: @unchecked Sendable {
    public private(set) var channel: Channel?
    private let adapter: SSHChannelAdapter?
    private let process: SystemSSHTerminalProcess?
    private let lock = NSLock()
    private var closed = false

    init(channel: Channel, adapter: SSHChannelAdapter, onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Error?) -> Void) {
        self.channel = channel
        self.adapter = adapter
        self.process = nil
        let notifier = CloseNotifier(onClose)
        adapter.onData = { data in
            onData(data)
        }
        adapter.onClose = { error in
            notifier.fire(error)
        }
        channel.closeFuture.whenComplete { _ in
            notifier.fire(nil)
        }
    }

    init(process: SystemSSHTerminalProcess, onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Error?) -> Void) {
        self.channel = nil
        self.adapter = nil
        self.process = process
        process.onData = { data in
            onData(data)
        }
        process.onClose = { error in
            onClose(error)
        }
    }

    public var isActive: Bool {
        if let process {
            return process.isRunning
        }
        return channel?.isActive ?? false
    }

    public func write(_ data: Data) {
        lock.lock()
        let closed = self.closed
        lock.unlock()
        guard !closed else { return }
        if let process {
            process.write(data)
            return
        }
        guard let channel, channel.isActive else { return }
        let buffer = channel.allocator.buffer(bytes: data)
        channel.writeAndFlush(buffer, promise: nil)
    }

    public func write(_ text: String) {
        write(Data(text.utf8))
    }

    public func resize(columns: Int, rows: Int) {
        if let process {
            process.resize(columns: columns, rows: rows)
            return
        }
        guard let channel else { return }
        let event = SSHChannelRequestEvent.WindowChangeRequest(terminalCharacterWidth: columns,
                                                               terminalRowHeight: rows,
                                                               terminalPixelWidth: 0,
                                                               terminalPixelHeight: 0)
        channel.triggerUserOutboundEvent(event, promise: nil)
    }

    public func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        if let process {
            process.terminate()
            return
        }
        channel?.close(mode: .all, promise: nil)
    }
}
