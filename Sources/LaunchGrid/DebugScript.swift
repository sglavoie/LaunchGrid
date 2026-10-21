import AppKit
import LaunchGridCore

/// Development aid: `LAUNCHGRID_DEBUG_SCRIPT="build;show;snap:grid;quit"` drives the UI and
/// writes PNG snapshots of our windows into `LAUNCHGRID_DEBUG_DIR` (default: the temp folder).
@MainActor
enum DebugScript {
    static func run(_ script: String, state: AppState, overlay: OverlayController, delegate: AppDelegate) {
        let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let dir = ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_DIR"] ?? NSTemporaryDirectory()
        Task {
            for step in steps {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                let arg = parts.count > 1 ? parts[1] : ""
                switch parts[0] {
                case "build": state.build(style: arg == "alpha" ? .alphabetical : .byCategory)
                case "show": overlay.show()
                case "hide": overlay.hide()
                case "page": state.goToPage(Int(arg) ?? 0)
                case "search": state.query = arg
                case "edit": state.editing = true
                case "select": for i in (arg.split(separator: ",").compactMap { Int($0) }) where state.currentItems.indices.contains(i) {
                    state.selection.insert(state.currentItems[i].id)
                }
                case "group": state.groupSelection()
                case "folder":
                    if let f = state.grid.pages.flatMap(\.items).compactMap(\.folder).first { state.openFolder(f.id) }
                case "focus": state.focusIndex = Int(arg) ?? 0
                case "rename": if let item = state.currentItems.first { state.beginRename(item.id) }
                case "settings": delegate.showSettings()
                case "missing": delegate.showAddMissing()
                case "undo": state.undo()
                case "keys":
                    // Comma-separated virtual key codes or literal characters, e.g. "keys:n,o,125,36".
                    guard let window = overlay.window else { break }
                    for token in arg.split(separator: ",").map(String.init) {
                        let code = UInt16(token).flatMap { token.count > 1 ? $0 : nil }
                        let chars = code == nil ? token : ""
                        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code ?? 0)
                        if let event { NSApp.postEvent(event, atStart: false) }
                        try? await Task.sleep(for: .milliseconds(120))
                    }
                case "state":
                    print("state: page=\(state.currentPage) query='\(state.query)' focus=\(String(describing: state.focusIndex)) folder=\(state.openFolder?.name ?? "-") folderPage=\(state.folderPage) shown=\(state.isShown) editing=\(state.editing)")
                    fflush(stdout)
                case "press":
                    // Long-press item N on the current page.
                    guard let window = overlay.window else { break }
                    let c = state.pageLayout.center(Int(arg) ?? 0)
                    let o = state.drag.pagerFrame.origin
                    let h = window.contentView?.bounds.height ?? 0
                    let p = NSPoint(x: o.x + c.x, y: h - (o.y + c.y))
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                      pressure: type == .leftMouseUp ? 0 : 1) {
                            NSApp.postEvent(e, atStart: false)
                        }
                        if type == .leftMouseDown { try? await Task.sleep(for: .seconds(1)) }
                    }
                case "drag", "merge", "edge", "fdrag":
                    let n = arg.split(separator: ",").compactMap { Int($0) }
                    guard let window = overlay.window, let from = n.first else { break }
                    await simulateDrag(parts[0], from: from, to: n.count > 1 ? n[1] : 0, state: state, window: window)
                case "pages": print("pages(\(state.currentPage)):", state.grid.pages.map { $0.items.prefix(5).map(\.title) + ["#\($0.items.count)"] }); fflush(stdout)
                case "wait": try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
                case "snap": snapshot(name: arg.isEmpty ? "snap" : arg, dir: dir)
                case "dump": print(String(data: (try? GridStore.encode(state.grid)) ?? Data(), encoding: .utf8) ?? "")
                case "quit": NSApp.terminate(nil)
                default: NSLog("LaunchGrid debug: unknown step \(step)")
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Sends real mouse events through the panel so the SwiftUI gesture path is exercised.
    /// drag: drop item `from` into the gap at slot `to`; merge: dwell on item `to`'s centre;
    /// edge: dwell at the right edge to flip a page, then drop at slot `to`.
    static func simulateDrag(_ kind: String, from: Int, to: Int, state: AppState, window: NSWindow) async {
        let layout = state.pageLayout
        let origin = state.drag.pagerFrame.origin
        func rootPoint(_ index: Int, dx: CGFloat = 0) -> CGPoint {
            let c = layout.center(index)
            return CGPoint(x: origin.x + c.x + dx, y: origin.y + c.y)
        }
        func send(_ type: NSEvent.EventType, _ p: CGPoint) {
            let h = window.contentView?.bounds.height ?? 0
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: h - p.y), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            if let event { NSApp.postEvent(event, atStart: false) }
        }
        func glide(_ a: CGPoint, _ b: CGPoint, steps: Int = 12) async {
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                send(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        var start = rootPoint(from)
        if kind == "fdrag" {
            let f = state.drag.folderGridFrame
            let fl = state.folderLayout
            let c = fl.center(from)
            start = CGPoint(x: f.minX + c.x, y: f.minY + c.y)
        }
        NSLog("LaunchGrid debug: active=\(NSApp.isActive) key=\(window.isKeyWindow) start=\(start)")
        send(.leftMouseDown, start)
        try? await Task.sleep(for: .milliseconds(50))
        var end: CGPoint
        switch kind {
        case "merge":
            end = rootPoint(to)
            await glide(start, end)
            for _ in 0..<8 { send(.leftMouseDragged, end); try? await Task.sleep(for: .milliseconds(100)) }
        case "edge":
            let frame = state.drag.pagerFrame
            let edge = CGPoint(x: frame.maxX - 10, y: frame.midY)
            await glide(start, edge)
            for _ in 0..<9 { send(.leftMouseDragged, edge); try? await Task.sleep(for: .milliseconds(100)) }
            end = rootPoint(to, dx: -layout.cell.width * 0.4)
            await glide(edge, end)
        default:
            end = rootPoint(to, dx: -layout.cell.width * 0.4)
            await glide(start, end)
        }
        try? await Task.sleep(for: .milliseconds(150))
        send(.leftMouseUp, end)
    }

    static func snapshot(name: String, dir: String) {
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView, view.bounds.width > 0,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(i).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            NSLog("LaunchGrid debug: wrote \(url.path)")
        }
    }
}
