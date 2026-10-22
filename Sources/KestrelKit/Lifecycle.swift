import Foundation

// Follows the app's lifecycle: queued signals are sent when the app moves to the
// background, and a new session starts when it comes back after 5 minutes or more.
// Only notification observers are used, and the application object comes from the
// notification rather than `UIApplication.shared`, which app extensions can't use.

#if os(watchOS)
import WatchKit

@MainActor
enum Lifecycle {
    static func observe(_ client: Client) {
        let center = NotificationCenter.default
        _ = center.addObserver(forName: WKApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { await client.didEnterBackground() }
        }
        _ = center.addObserver(forName: WKApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            client.willEnterForeground()
        }
    }
}

#elseif canImport(UIKit)
import UIKit

@MainActor
enum Lifecycle {
    static func observe(_ client: Client) {
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { note in
            let application = note.object as? UIApplication
            MainActor.assumeIsolated {
                // Ask for a little time so the upload can finish after the app is suspended.
                let task = BackgroundTask(application)
                Task { @MainActor in
                    await client.didEnterBackground()
                    task.end()
                }
            }
        }
        _ = center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            client.willEnterForeground()
        }
    }
}

@MainActor
private final class BackgroundTask {
    private let application: UIApplication?
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(_ application: UIApplication?) {
        self.application = application
        identifier = application?.beginBackgroundTask(withName: "KestrelKit upload") { [weak self] in
            MainActor.assumeIsolated {
                self?.end()
            }
        } ?? .invalid
    }

    func end() {
        guard identifier != .invalid else { return }
        application?.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

#elseif canImport(AppKit)
import AppKit

/// On the Mac, "background" means another app is active.
@MainActor
enum Lifecycle {
    static func observe(_ client: Client) {
        let center = NotificationCenter.default
        _ = center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            Task { await client.didEnterBackground() }
        }
        _ = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            client.willEnterForeground()
        }
    }
}

#else

/// No app lifecycle (Linux, where only the core is built and tested).
@MainActor
enum Lifecycle {
    static func observe(_ client: Client) {}
}

#endif
