import AppKit

nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

MainActor.assumeIsolated {
    // `just uninstall`: drop the login item while the bundle that registered it still exists.
    if CommandLine.arguments.contains("--unregister-login-item") {
        guard LoginItem.isRequested else {
            print("LaunchGrid: no login item to remove")
            exit(0)
        }
        do {
            try LoginItem.set(false)
            print("LaunchGrid: login item removed")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("LaunchGrid: could not remove the login item: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    // Single instance: hand over to the running copy and quit. A scratch run keeps its own
    // data, so it runs beside the installed copy, but not beside another using that data.
    let lock = AppDelegate.acquireInstanceLock()
    if case .unavailable(let code) = lock {
        let detail = String(localized: "LaunchGrid could not secure its layout against another running copy. \(String(cString: strerror(code)))")
        FileHandle.standardError.write(Data("LaunchGrid: \(detail)\n".utf8))
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Could not start LaunchGrid")
        alert.informativeText = detail
        alert.runModal()
        exit(1)
    }
    if Preferences.isScratch && lock == .held {
        print("LaunchGrid: another scratch run uses \(AppDelegate.storeURL.deletingLastPathComponent().path)")
        exit(0)
    }
    if !Preferences.isScratch && (lock == .held || !AppDelegate.otherInstances.isEmpty) {
        DistributedNotificationCenter.default().postNotificationName(
            AppDelegate.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
        exit(0)
    }

    if Preferences.isScratch {
        AppDelegate.writeScratchMarker()
        atexit { try? FileManager.default.removeItem(at: AppDelegate.scratchMarker(for: getpid())) }
    }
    // Ctrl-C or kill (scripts/install.sh quits the installed copy that way) would skip
    // applicationWillTerminate, losing a pending save, and atexit; turn them into a normal quit.
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        signalSources.append(source)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
