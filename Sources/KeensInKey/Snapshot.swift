import SwiftUI
import AppKit
import KeensInKeyCore

/// Debug aid: when KIK_SNAPSHOT_DIR is set, the app loads KIK_SNAPSHOT_FILES (colon separated),
/// waits for analysis, renders every page of the main window to PNG files and quits.
/// Used to produce README screenshots and for UI verification in headless environments.
@MainActor
enum SnapshotRunner {
    private static var started = false
    /// True while running in snapshot mode (long pages render without scroll views so they can be captured).
    static let active = ProcessInfo.processInfo.environment["KIK_SNAPSHOT_DIR"] != nil

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
            // Sample collection / playlists / tags for the screenshots.
            if library.collections.isEmpty, library.tracks.count >= 2 {
                let ids = library.tracks.map(\.id)
                let col = library.createNode(name: "Saturday Night", emoji: "🔥", kind: .folder)
                let warm = library.createNode(name: "Warm-up", emoji: "🌙", kind: .playlist, under: col.id, trackIds: Array(ids.prefix(2)))
                _ = library.createNode(name: "Peak Time", emoji: "⚡️", kind: .playlist, under: col.id, trackIds: Array(ids.dropFirst(2).prefix(3)))
                var rules = SmartRules(); rules.minEnergy = 7; rules.sort = .energyDescending
                _ = library.createNode(name: "High Energy", emoji: "✨", kind: .smart, under: col.id, rules: rules)
                if let vocal = library.tagCategories.first(where: { $0.name == "Components" })?.tags.first(where: { $0.name == "Vocal" }),
                   let peak = library.tagCategories.first(where: { $0.name == "Situation" })?.tags.first(where: { $0.name == "Peak time" }) {
                    library.setTag(vocal.id, on: Set(ids.prefix(3)), enabled: true)
                    library.setTag(peak.id, on: Set(ids.dropFirst(1).prefix(3)), enabled: true)
                }
                state.playlistSelection = warm.id
                state.showTagPanel = true
                state.page = .analyze
                try? await Task.sleep(nanoseconds: 700_000_000)
                snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("collection.png"))
                state.playlistSelection = nil
                state.showTagPanel = false
            }
            for page in Page.allCases {
                state.page = page
                if page == .wheel { state.wheelKey = nil }
                let tall = page == .personalize || page == .settings
                if let window = NSApp.windows.first(where: { $0.frame.width > 400 }) {
                    window.setContentSize(NSSize(width: 1240, height: tall ? 1560 : 780))
                }
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
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            NSLog("snapshot: wrote \(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        }
    }
}
