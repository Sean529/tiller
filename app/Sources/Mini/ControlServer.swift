import AppKit
import CMiniCore

struct ControlError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Answers mini_mcp's tab requests (list, open, select, navigate, close) that
/// arrive on the control socket. DevTools calls on the same socket never reach
/// Swift; the core sends them to the tab directly.
@MainActor
final class ControlServer {
    /// Where mini_mcp looks, unless its MINI_SOCKET variable says otherwise.
    static let socketPath = NSHomeDirectory() + "/Library/Application Support/Mini/control.sock"

    weak var browser: BrowserWindowController?

    /// The server lives for the rest of the process once started.
    func start() -> Bool {
        let ctx = Unmanaged.passRetained(self).toOpaque()
        return mini_ipc_start(Self.socketPath, ctx) { ctx, request, token in
            guard let ctx, let request else { return }
            ControlServer.from(ctx).handle(String(cString: request), token: token)
        }
    }

    nonisolated private static func from(_ ctx: UnsafeMutableRawPointer) -> ControlServer {
        Unmanaged<ControlServer>.fromOpaque(ctx).takeUnretainedValue()
    }

    nonisolated private func handle(_ json: String, token: UInt64) {
        MainActor.assumeIsolated {
            var reply: [String: Any]
            do {
                guard let request = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                    let method = request["method"] as? String
                else { throw ControlError("request needs a method") }
                guard let browser else { throw ControlError("no browser window is open") }
                let params = request["params"] as? [String: Any] ?? [:]
                reply = ["result": try browser.control(method, params: params)]
            } catch let error as ControlError {
                reply = ["error": error.message]
            } catch {
                reply = ["error": "\(error)"]
            }
            let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(#"{"error":"could not encode reply"}"#.utf8)
            String(decoding: data, as: UTF8.self).withCString { mini_ipc_reply(token, $0) }
        }
    }
}
