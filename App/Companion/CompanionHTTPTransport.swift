import Foundation
import Shared

/// Explicit private transport with bounded responses and generation-fenced task resume.
public actor CompanionHTTPTransport: CompanionTransport {
    public typealias Admission = @Sendable (_ resume: () -> Void) throws -> Void
    private let baseURL: URL
    private let token: String
    private let admission: Admission
    private let receiver: CompanionHTTPReceiver
    private let session: URLSession
    private var closed = false
    public init(baseURL: URL, bearerToken: String, admission: @escaping Admission = { $0() }) throws {
        guard let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/", "/retrace-companion", "/retrace-companion/"].contains(parts.path), let host = parts.host,
              parts.scheme == "https" || (parts.scheme == "http" && ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host)),
              (32...4096).contains(bearerToken.utf8.count),
              bearerToken.utf8.allSatisfy({ (33...126).contains($0) }) else { throw CompanionError.invalidPayload }
        self.baseURL = baseURL; token = bearerToken; self.admission = admission
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        receiver = CompanionHTTPReceiver()
        session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
    }
    public func publishObject(sha256: String, data: Data) async throws {
        guard (1...16 * 1024 * 1024).contains(data.count), CompanionWire.digest(data) == sha256 else { throw CompanionError.invalidPayload }
        _ = try await send("PUT", resource: "objects", id: sha256, body: data, maximum: 4096, accepted: [200])
    }
    public func publishJob(id: String, data: Data) async throws {
        guard data.count <= 768 * 1024, CompanionWire.digest(data) == id else { throw CompanionError.invalidPayload }
        _ = try await send("POST", resource: "jobs", id: id, body: data, maximum: 4096, accepted: [200])
    }
    public func result(id: String) async throws -> Data? {
        let (status, data) = try await send("GET", resource: "results", id: id, maximum: 2 * 1024 * 1024, accepted: [200, 202])
        return status == 200 ? data : nil
    }
    public func acknowledge(id: String, resultSHA256: String) async throws {
        try CompanionBounds.digest(resultSHA256)
        _ = try await send("POST", resource: "acks", id: id, body: CompanionWire.encode(["sha256": resultSHA256]), maximum: 4096, accepted: [200])
    }
    public func close() { closed = true; session.invalidateAndCancel() }
    private func send(_ method: String, resource: String, id: String, body: Data? = nil,
                      maximum: Int, accepted: Set<Int>) async throws -> (Int, Data) {
        guard !closed else { throw CompanionError.closed }; try Task.checkCancellation(); try CompanionBounds.digest(id)
        let url = baseURL.appendingPathComponent("v1").appendingPathComponent(resource).appendingPathComponent(id)
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(resource == "objects" ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type")
        let cancellation = CompanionHTTPCancellation()
        // Capture the request's evidence revision before crossing the URLSession boundary.
        let evidenceAdmission = CompanionTransportAdmission.current
        let value: (Int, Data) = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                receiver.register(task: task, maximum: maximum, accepted: accepted, continuation: continuation)
                do {
                    try cancellation.bind(task)
                    var rejected: (any Error)?
                    try admission {
                        if let evidenceAdmission {
                            do { try evidenceAdmission { cancellation.resume(task) } }
                            catch { rejected = error }
                        } else { cancellation.resume(task) }
                    }
                    if let rejected { throw rejected }
                } catch { receiver.reject(task: task, error: error); task.cancel() }
            }
        }, onCancel: { cancellation.cancel() })
        try Task.checkCancellation(); return value
    }
}
private final class CompanionHTTPCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func bind(_ task: URLSessionTask) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }; self.task = task
    }
    func resume(_ task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        if cancelled { task.cancel() } else { task.resume() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel()
    }
}
private final class CompanionHTTPReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Transfer {
        let maximum: Int
        let accepted: Set<Int>
        let continuation: CheckedContinuation<(Int, Data), Error>
        var status: Int?
        var data = Data()
        var failure: (any Error)?
    }
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    func register(task: URLSessionTask, maximum: Int, accepted: Set<Int>, continuation: CheckedContinuation<(Int, Data), Error>) {
        lock.lock(); defer { lock.unlock() }
        transfers[task.taskIdentifier] = Transfer(maximum: maximum, accepted: accepted, continuation: continuation)
    }
    func reject(task: URLSessionTask, error: any Error) {
        lock.lock(); let transfer = transfers.removeValue(forKey: task.taskIdentifier); lock.unlock()
        transfer?.continuation.resume(throwing: error)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard var transfer = transfers[dataTask.taskIdentifier] else { lock.unlock(); completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse, transfer.accepted.contains(response.statusCode),
              response.expectedContentLength <= transfer.maximum else {
            transfer.failure = CompanionError.transportRejected; transfers[dataTask.taskIdentifier] = transfer
            lock.unlock(); completionHandler(.cancel); return
        }
        transfer.status = response.statusCode; transfers[dataTask.taskIdentifier] = transfer
        lock.unlock(); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var transfer = transfers[dataTask.taskIdentifier] else { lock.unlock(); dataTask.cancel(); return }
        if data.count > transfer.maximum - transfer.data.count {
            transfer.failure = CompanionError.invalidPayload; transfers[dataTask.taskIdentifier] = transfer
            lock.unlock(); dataTask.cancel(); return
        }
        transfer.data.append(data); transfers[dataTask.taskIdentifier] = transfer; lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock(); let transfer = transfers.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let transfer else { return }
        if let error = transfer.failure ?? error { transfer.continuation.resume(throwing: error) }
        else if let status = transfer.status { transfer.continuation.resume(returning: (status, transfer.data)) }
        else { transfer.continuation.resume(throwing: CompanionError.transportRejected) }
    }
}
