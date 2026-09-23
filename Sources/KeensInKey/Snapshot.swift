import SwiftUI
import AppKit
import KeensInKeyCore

/// Debug aid: when KIK_SNAPSHOT_DIR is set, the app loads KIK_SNAPSHOT_FILES (colon separated),
/// waits for analysis, renders every page of the main window to PNG files and quits.
/// Used to produce README screenshots and for UI verification in headless environments.
@MainActor
enum SnapshotRunner {
    private static var started = false

    static func runIfRequested(library: LibraryStore, settings: AppSettings, analysis: AnalysisController, state: AppState, player: Player) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["KIK_SNAPSHOT_DIR"], !started else { return }
        started = true
        let files = (env["KIK_SNAPSHOT_FILES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? await Task.sleep(nanoseconds: 800_000_000)
            let ids = library.add(urls: files)
            analysis.enqueue(ids)
            // Wait for analysis to finish (max 120 s).
            var waited = 0
            while (analysis.isRunning || library.tracks.contains { $0.status == .queued || $0.status == .analyzing }) && waited < 1200 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let first = library.tracks.first(where: { $0.result != nil }) {
                state.selection = [first.id]
                player.load(first)
                player.seek(to: min(20, (first.result?.duration ?? 0) / 3))
            }
            for page in Page.allCases {
                state.page = page
                if page == .wheel { state.wheelKey = nil }
                try? await Task.sleep(nanoseconds: 700_000_000)
                snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("\(page.rawValue).png"))
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.terminate(nil)
        }
    }

    static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }) ?? NSApp.windows.first,
              let view = window.contentView else {
            NSLog("snapshot: no window")
            return
        }
        view.displayIfNeeded()
        window.displayIfNeeded()
        // Method 1: window-server capture of the live window (works when the window is on screen).
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
           cg.width > 100 {
            let rep = NSBitmapImageRep(cgImage: cg)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
                NSLog("snapshot: wrote \(url.path) via window server (\(cg.width)x\(cg.height))")
            }
        }
        // Method 2: layer tree render (fallback, also written next to it for comparison).
        if let layer = view.layer {
            let scale = window.backingScaleFactor
            let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
                ctx.scaleBy(x: scale, y: scale)
                if !view.isFlipped { ctx.translateBy(x: 0, y: view.bounds.height); ctx.scaleBy(x: 1, y: -1) }
                layer.render(in: ctx)
                if let cg = ctx.makeImage() {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    let alt = url.deletingPathExtension().appendingPathExtension("layer.png")
                    if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: alt) }
                }
            }
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            let alt = url.deletingPathExtension().appendingPathExtension("cache.png")
            try? data.write(to: alt)
            if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url) }
            NSLog("snapshot: wrote \(alt.path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        }
    }
}
