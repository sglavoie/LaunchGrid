import AppKit

MainActor.assumeIsolated {
    // Single instance: hand over to the running copy and quit.
    if let id = Bundle.main.bundleIdentifier {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(
                AppDelegate.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
            exit(0)
        }
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
