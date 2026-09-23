import Foundation
import SwiftUI
import KeensInKeyCore

/// Runs analyses in the background with bounded parallelism and reports progress to the library.
@Observable
final class AnalysisController {
    private(set) var isRunning = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var lastError: String?
    var statusMessage = ""

    private var pending: [UUID] = []
    private var runner: Task<Void, Never>?
    private weak var library: LibraryStore?
    private weak var settings: AppSettings?
    var tagWriter: TagWriteCoordinator?

    func bind(library: LibraryStore, settings: AppSettings) {
        self.library = library
        self.settings = settings
    }

    /// Queues the given tracks and starts the runner if needed.
    func enqueue(_ ids: [UUID], force: Bool = false) {
        guard let library else { return }
        var added = 0
        for id in ids {
            guard let t = library.track(id) else { continue }
            if !force, t.status == .done || t.status == .queued || t.status == .analyzing { continue }
            if pending.contains(id) { continue }
            pending.append(id)
            library.update(id) { $0.status = .queued; $0.progress = 0; $0.stage = "Queued"; $0.errorMessage = nil }
            added += 1
        }
        if added == 0 { return }
        total += added
        if runner == nil { start() }
    }

    func stop() {
        pending.removeAll()
        runner?.cancel()
        runner = nil
        isRunning = false
        library?.tracks.filter { $0.status == .queued }.forEach { t in
            library?.update(t.id) { $0.status = t.result == nil ? .pending : .done; $0.stage = "" }
        }
        statusMessage = "Stopped"
        total = 0
        completed = 0
    }

    private func start() {
        guard let library, let settings else { return }
        isRunning = true
        completed = 0
        total = pending.count
        statusMessage = "Analyzing…"
        let concurrency = max(1, settings.concurrency)
        let options = settings.analysis
        runner = Task { @MainActor [weak self] in
            await withTaskGroup(of: UUID.self) { group in
                var active = 0
                while true {
                    if Task.isCancelled { break }
                    guard let self else { break }
                    while active < concurrency, !self.pending.isEmpty {
                        let id = self.pending.removeFirst()
                        guard let track = library.track(id) else { continue }
                        active += 1
                        library.update(id) { $0.status = .analyzing; $0.stage = "Starting"; $0.progress = 0 }
                        group.addTask {
                            await AnalysisController.analyze(track: track, options: options, library: library)
                            return id
                        }
                    }
                    if active == 0 { break }
                    guard let finished = await group.next() else { break }
                    active -= 1
                    self.completed += 1
                    if library.track(finished)?.status == .done {
                        await self.tagWriter?.autoWriteIfEnabled(trackId: finished)
                    }
                }
            }
            guard let self else { return }
            self.isRunning = false
            self.runner = nil
            self.statusMessage = self.completed > 0 ? "Analyzed \(self.completed) track\(self.completed == 1 ? "" : "s")" : ""
            if !self.pending.isEmpty { self.start() }
        }
    }

    private static func analyze(track: Track, options: TrackAnalyzer.Options, library: LibraryStore) async {
        let id = track.id
        let url = track.url
        let result: Result<AnalysisResult, Error> = await Task.detached(priority: .userInitiated) {
            do {
                var lastReport = Date.distantPast
                let r = try TrackAnalyzer(options: options).analyze(url: url) { p, stage in
                    let now = Date()
                    if now.timeIntervalSince(lastReport) > 0.15 || p >= 1 {
                        lastReport = now
                        Task { @MainActor in library.update(id) { $0.progress = p; $0.stage = stage } }
                    }
                }
                return .success(r)
            } catch {
                return .failure(error)
            }
        }.value
        await MainActor.run {
            switch result {
            case .success(let r):
                library.update(id) { t in
                    t.result = r
                    t.status = .done
                    t.progress = 1
                    t.stage = ""
                    t.duration = r.duration
                    t.errorMessage = nil
                }
            case .failure(let e):
                library.update(id) { t in
                    t.status = .failed
                    t.progress = 0
                    t.stage = ""
                    t.errorMessage = e.localizedDescription
                }
            }
        }
    }
}

/// Writes tags for tracks according to the personalisation options.
@MainActor
final class TagWriteCoordinator {
    private let library: LibraryStore
    private let settings: AppSettings
    private(set) var busy = false

    init(library: LibraryStore, settings: AppSettings) {
        self.library = library
        self.settings = settings
    }

    func autoWriteIfEnabled(trackId: UUID) async {
        guard settings.tagOptions.autoWriteAfterAnalysis else { return }
        guard let t = library.track(trackId), t.result != nil, t.tagsWrittenAt == nil else { return }
        _ = await write(ids: [trackId])
    }

    /// Returns (written, errors).
    @discardableResult
    func write(ids: [UUID]) async -> (Int, [String]) {
        busy = true
        defer { busy = false }
        var written = 0
        var errors: [String] = []
        let options = settings.tagOptions
        for id in ids {
            guard let t = library.track(id), let result = t.result else { continue }
            let existing = await TagService.read(t.url)
            let title = existing.title ?? t.displayTitle
            let artist = existing.artist ?? t.artist
            let fields = TagService.fields(for: result, existing: existing, options: options, title: title, artist: artist)
            let rename = options.renameFile
                ? options.expand(options.fileNameFormat, key: result.key.key, energy: result.energy, bpm: result.tempo.bpm, title: title, artist: artist)
                : nil
            do {
                let newURL = try await TagService.write(fields, to: t.url, rename: rename)
                let refreshed = await TagService.read(newURL)
                library.update(id) { tr in
                    tr.path = newURL.path
                    tr.existingTags = refreshed
                    if let ti = refreshed.title, !ti.isEmpty { tr.title = ti }
                    tr.tagsWrittenAt = Date()
                }
                written += 1
            } catch {
                errors.append("\(t.fileName): \(error.localizedDescription)")
            }
        }
        return (written, errors)
    }
}
