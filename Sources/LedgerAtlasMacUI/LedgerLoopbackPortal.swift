import AppKit
import Foundation
@preconcurrency import Network

public struct LedgerPortalProjection: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable { case empty, ready, locked }

  public let schemaVersion: Int
  public let state: State
  public let accountCount: Int
  public let transactionCount: Int

  public init(state: State, accountCount: Int = 0, transactionCount: Int = 0) {
    schemaVersion = 1
    self.state = state
    self.accountCount = max(0, accountCount)
    self.transactionCount = max(0, transactionCount)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, state, accountCount, transactionCount
  }
}

private final class PortalContinuationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var resumed = false

  func claim() -> Bool {
    lock.withLock {
      guard !resumed else { return false }
      resumed = true
      return true
    }
  }
}

public final class LedgerLoopbackPortal: @unchecked Sendable {
  public enum Error: Swift.Error, Equatable, Sendable {
    case alreadyRunning
    case couldNotBind
    case unavailable
  }

  private let queue = DispatchQueue(label: "com.praxstack.ledgeratlas.loopback-portal")
  private let idleTimeout: TimeInterval
  private var listener: NWListener?
  private var idleWork: DispatchWorkItem?
  private var observer: NSObjectProtocol?
  private var token = ""
  private var endpointURL: URL?

  public init(idleTimeout: TimeInterval = 900) {
    self.idleTimeout = max(1, idleTimeout)
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
    ) { [weak self] _ in
      self?.stop()
    }
  }

  deinit {
    if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    stop()
  }

  public var url: URL? { endpointURL }

  /// Called after the portal stops for any reason: a request, sleep, or the idle timeout.
  public var onStop: (@Sendable () -> Void)?

  @MainActor
  public func start(projection: LedgerPortalProjection) async throws -> URL {
    guard listener == nil else { throw Error.alreadyRunning }
    token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let responseData: Data
    do {
      responseData = try JSONEncoder().encode(projection)
    } catch {
      throw Error.unavailable
    }
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(
      host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: 0)!)
    let listener: NWListener
    do {
      listener = try NWListener(using: parameters)
    } catch {
      throw Error.couldNotBind
    }
    self.listener = listener
    return try await withCheckedThrowingContinuation { continuation in
      let gate = PortalContinuationGate()
      listener.stateUpdateHandler = { [weak self, weak listener] state in
        guard let self else { return }
        switch state {
        case .ready:
          guard let port = listener?.port, gate.claim() else { return }
          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/status?token=\(self.token)")!
          self.endpointURL = url
          self.armIdleTimer()
          continuation.resume(returning: url)
        case .failed:
          guard gate.claim() else { return }
          self.stop()
          continuation.resume(throwing: Error.couldNotBind)
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        self?.accept(connection, responseData: responseData)
      }
      listener.start(queue: self.queue)
    }
  }

  public func stop() {
    let wasRunning = listener != nil
    listener?.cancel()
    listener = nil
    idleWork?.cancel()
    idleWork = nil
    endpointURL = nil
    token = ""
    if wasRunning { onStop?() }
  }

  /// Pure request handling keeps the network boundary testable without exposing private data.
  public static func response(
    request: String, token: String, projectionData: Data
  ) -> (status: Int, body: Data) {
    let line = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? ""
    let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
    guard parts.count == 3, parts[0] == "GET" else { return (405, Data()) }
    guard let components = URLComponents(string: "http://localhost\(parts[1])"),
      components.path == "/status"
    else { return (404, Data()) }
    guard components.queryItems?.first(where: { $0.name == "token" })?.value == token else {
      return (401, Data())
    }
    return (200, projectionData)
  }

  private func accept(_ connection: NWConnection, responseData: Data) {
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else { return }
      switch state {
      case .ready:
        self.receive(on: connection, responseData: responseData)
      case .failed, .cancelled:
        break
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  private func receive(on connection: NWConnection, responseData: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self, weak connection] data, _, _, _ in
      guard let self, let connection else { return }
      let request = String(decoding: data ?? Data(), as: UTF8.self)
      let result = Self.response(request: request, token: self.token, projectionData: responseData)
      let reason = switch result.status {
      case 200: "OK"
      case 401: "Unauthorized"
      case 404: "Not Found"
      default: "Method Not Allowed"
      }
      let headers = "HTTP/1.1 \(result.status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(result.body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
      var reply = Data(headers.utf8)
      reply.append(result.body)
      connection.send(content: reply, completion: .contentProcessed { [weak self, weak connection] _ in
        connection?.cancel()
        if result.status == 200 { self?.armIdleTimer() }
      })
    }
  }

  private func armIdleTimer() {
    idleWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.stop() }
    idleWork = work
    queue.asyncAfter(deadline: .now() + idleTimeout, execute: work)
  }
}
