import AppKit
import CTillerCore

struct ControlError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// A result that comes later: `start` is given the function to call with
/// the result, or a `ControlError`, once it is known.
final class ControlDeferred {
    let start: (@escaping (Result<Any, ControlError>) -> Void) -> Void
    init(_ start: @escaping (@escaping (Result<Any, ControlError>) -> Void) -> Void) { self.start = start }
}

/// Answers tiller_mcp's tab requests (list, open, select, navigate, close) and
/// skill requests (list, read, save) and schedule requests (list, save,
/// delete, run) that arrive on the control socket. DevTools calls on the same socket never reach
/// Swift; the core sends them to the tab directly.
@MainActor
final class ControlServer {
    /// `control.sock` in the profile's folder. Both the app and tiller_mcp
    /// honor TILLER_SOCKET, for folders whose path is too long for a socket.
    /// Agents are given this path in TILLER_SOCKET.
    static let socketPath = ProcessInfo.processInfo.environment["TILLER_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
        ?? DataDirectory.file("control.sock")

    weak var browser: BrowserWindowController?

    /// The server lives for the rest of the process once started.
    func start() -> Bool {
        let ctx = Unmanaged.passRetained(self).toOpaque()
        return tiller_ipc_start(Self.socketPath, ctx) { ctx, request, token in
            guard let ctx, let request else { return }
            ControlServer.from(ctx).handle(String(cString: request), token: token)
        }
    }

    nonisolated private static func from(_ ctx: UnsafeMutableRawPointer) -> ControlServer {
        Unmanaged<ControlServer>.fromOpaque(ctx).takeUnretainedValue()
    }

    nonisolated private func handle(_ json: String, token: UInt64) {
        MainActor.assumeIsolated {
            let result: Any
            do {
                guard let request = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                    let method = request["method"] as? String
                else { throw ControlError("request needs a method") }
                let params = request["params"] as? [String: Any] ?? [:]
                if method.hasPrefix("skills.") {
                    result = try AgentSkillCatalog.control(method, params: params)
                } else if method.hasPrefix("schedules.") {
                    result = try AgentScheduleControl.control(method, params: params)
                } else {
                    guard let browser else { throw ControlError("no browser window is open") }
                    result = try browser.control(method, params: params)
                }
            } catch let error as ControlError {
                return Self.send(["error": error.message], token: token)
            } catch {
                return Self.send(["error": "\(error)"], token: token)
            }
            // A result that waits on the page answers when it is ready.
            if let deferred = result as? ControlDeferred {
                deferred.start { outcome in
                    switch outcome {
                    case .success(let value): Self.send(["result": value], token: token)
                    case .failure(let error): Self.send(["error": error.message], token: token)
                    }
                }
            } else {
                Self.send(["result": result], token: token)
            }
        }
    }

    private static func send(_ reply: [String: Any], token: UInt64) {
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(#"{"error":"could not encode reply"}"#.utf8)
        String(decoding: data, as: UTF8.self).withCString { tiller_ipc_reply(token, $0) }
    }
}
