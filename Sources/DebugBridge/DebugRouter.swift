// Debug builds only (D43): the public Release build must not contain the
// agent control channel or its helpers, not merely have them switched off.
#if DEBUG

import Foundation

/// What the app must supply for the bridge to be able to drive it.
///
/// Rule (ARCHITECTURE.md): every UI state a human can reach must be reachable
/// through here without a physical mouse hover.
@MainActor
protocol DebugBridgeDelegate: AnyObject {
    func debugStatus() -> DebugStatus
    /// Must return only once the requested transition has settled, so callers
    /// never race an animation.
    func debugPerform(_ command: DebugCommandRequest) async throws -> DebugStatus
}

enum DebugRouterError: LocalizedError {
    case unknownCommand(String)
    case missingArgument(String)
    case notReady(String)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let name): "unknown command: \(name)"
        case .missingArgument(let name): "missing argument: \(name)"
        case .notReady(let what): "not ready: \(what)"
        }
    }
}

@MainActor
final class DebugRouter {
    weak var delegate: DebugBridgeDelegate?

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    func route(_ request: HTTPRequest) async -> (Int, Data) {
        guard let delegate else {
            return (500, encode(DebugError(error: "no delegate wired")))
        }

        switch (request.method, request.path) {
        case ("GET", "/status"):
            return (200, encode(delegate.debugStatus()))

        case ("POST", "/command"):
            do {
                let command = try JSONDecoder().decode(DebugCommandRequest.self, from: request.body)
                let status = try await delegate.debugPerform(command)
                return (200, encode(status))
            } catch let error as DecodingError {
                return (400, encode(DebugError(error: "bad request body: \(error)")))
            } catch {
                return (400, encode(DebugError(error: error.localizedDescription)))
            }

        case ("GET", "/health"):
            return (200, Data(#"{"ok":true}"#.utf8))

        default:
            return (404, encode(DebugError(error: "no route for \(request.method) \(request.path)")))
        }
    }

    private func encode(_ value: some Encodable) -> Data {
        (try? encoder.encode(value)) ?? Data(#"{"error":"encoding failed"}"#.utf8)
    }
}

#endif
