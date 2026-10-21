import AppKit

nonisolated(unsafe) var scratchSignalSources: [DispatchSourceSignal] = []

MainActor.assumeIsolated {
    // Single instance: hand over to the running copy and quit. A scratch run keeps its own
    // data, so it runs beside the installed copy.
    if !Preferences.isScratch && !AppDelegate.otherInstances.isEmpty {
        DistributedNotificationCenter.default().postNotificationName(
            AppDelegate.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
        exit(0)
    }

    if Preferences.isScratch {
        let marker = AppDelegate.scratchMarker(for: ProcessInfo.processInfo.processIdentifier)
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        atexit { try? FileManager.default.removeItem(at: AppDelegate.scratchMarker(for: getpid())) }
        // Ctrl-C or kill skips atexit, so turn them into a normal quit.
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            scratchSignalSources.append(source)
        }
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
