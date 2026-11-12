import Foundation
import Network
import Shared

/// One-request HTTP/1.1 bridge on the laptop loopback interface. The private primary-host
/// transport forwards this port; the bridge still authenticates the original client token.
/// This listener does not expose the recording database, arbitrary URLs, or native file paths.
public actor RetraceNativeBridge {
    private let dispatcher: RetraceCommandDispatcher
    private let port: UInt16
    private let queue = DispatchQueue(label: "Retrace.NativeCommandBridge", qos: .utility)
    private var listener: NWListener?
    private var terminal = false
    private var listening = false
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var connections: [UUID: (NWConnection, Task<Void, Never>)] = [:]
    public init(dispatcher: RetraceCommandDispatcher, port: UInt16 = 9013) {
        self.dispatcher = dispatcher; self.port = port
    }
    public func isListening() -> Bool { listening }
    public func start() async throws {
        guard !terminal, listener == nil, port > 0 else { throw RetraceCommandError.unavailable }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.listenerChanged(state) }
        }
        self.listener = listener
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startWaiter = continuation
                listener.start(queue: queue)
            }
        } onCancel: { listener.cancel() }
    }
    public func close() async {
        terminal = true
        listening = false
        startWaiter?.resume(throwing: RetraceCommandError.unavailable); startWaiter = nil
        listener?.cancel(); listener = nil
        let admitted = Array(connections.values)
        for (connection, task) in admitted { task.cancel(); connection.cancel() }
        for (_, task) in admitted { await task.value }
        connections.removeAll()
    }
    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard !terminal else { return }
            listening = true
            startWaiter?.resume(); startWaiter = nil
        case .failed(let error):
            listening = false
            startWaiter?.resume(throwing: error); startWaiter = nil
            listener?.cancel(); listener = nil
        case .cancelled:
            listening = false
            startWaiter?.resume(throwing: CancellationError()); startWaiter = nil
        default: break
        }
    }
    private func accept(_ connection: NWConnection) {
        guard !terminal, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connection.start(queue: queue)
        let task = Task { [self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.serve(connection) }
                group.addTask {
                    do { try await Task.sleep(for: .seconds(15)); connection.cancel() } catch { }
                }
                _ = await group.next()
                group.cancelAll()
                connection.cancel()
            }
            await finished(id)
        }
        connections[id] = (connection, task)
    }
    private func finished(_ id: UUID) { connections[id] = nil }
    private func serve(_ connection: NWConnection) async {
        do {
            var data = Data()
            var parsed: RetraceBridgeHTTPRequest?
            while parsed == nil {
                try Task.checkCancellation()
                let (chunk, complete) = try await read(connection)
                data.append(chunk)
                parsed = try RetraceBridgeHTTPRequest.parse(data, port: port)
                if complete && parsed == nil { throw RetraceCommandError.invalidArguments }
            }
            guard let parsed else { throw RetraceCommandError.invalidArguments }
            let request = try RetraceWire.decoder().decode(RetraceCommandRequest.self, from: parsed.body)
            let result = await dispatcher.execute(request, bearerToken: parsed.token)
            let status = result.status == .denied ? 403 : 200
            try await send(connection, status: status, body: RetraceWire.encoder().encode(result))
        } catch {
            try? await send(connection, status: 400, body: Data("{\"status\":\"failed\",\"code\":\"invalid_request\",\"queued\":false}".utf8))
        }
    }
    private func read(_ connection: NWConnection) async throws -> (Data, Bool) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: (data ?? Data(), complete)) }
                }
            }
        } onCancel: { connection.cancel() }
    }
    private func send(_ connection: NWConnection, status: Int, body: Data) async throws {
        guard body.count <= 1_048_576 else { throw RetraceCommandError.invalidArguments }
        var data = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Rejected")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n".utf8)
        data.append(body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

struct RetraceBridgeHTTPRequest {
    let token: String
    let body: Data
    static func parse(_ data: Data, port: UInt16) throws -> Self? {
        guard data.count <= 73_728 else { throw RetraceCommandError.invalidArguments }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 8192 else { throw RetraceCommandError.invalidArguments }
            return nil
        }
        guard separator.lowerBound <= 8192, let header = String(data: data[..<separator.lowerBound], encoding: .ascii) else { throw RetraceCommandError.invalidArguments }
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first == "POST /v1/command HTTP/1.1", lines.count <= 32 else { throw RetraceCommandError.invalidArguments }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let split = line.firstIndex(of: ":") else { throw RetraceCommandError.invalidArguments }
            let name = String(line[..<split]).lowercased()
            let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }), fields[name] == nil else { throw RetraceCommandError.invalidArguments }
            fields[name] = value
        }
        guard fields["host"] == "127.0.0.1:\(port)" || fields["host"] == "localhost:\(port)",
              fields["origin"] == nil, fields["transfer-encoding"] == nil,
              fields["content-type"]?.lowercased() == "application/json",
              let lengthString = fields["content-length"], lengthString.allSatisfy(\.isNumber),
              let length = Int(lengthString), (1...65_536).contains(length),
              let authorization = fields["authorization"], authorization.hasPrefix("Bearer ") else { throw RetraceCommandError.invalidArguments }
        let token = String(authorization.dropFirst(7))
        guard (32...512).contains(token.utf8.count), token.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) else { throw RetraceCommandError.invalidArguments }
        let count = data.count - separator.upperBound
        guard count <= length else { throw RetraceCommandError.invalidArguments }
        if count < length { return nil }
        return .init(token: token, body: Data(data[separator.upperBound...]))
    }
}
