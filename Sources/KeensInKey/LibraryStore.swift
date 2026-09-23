import Foundation
import SwiftUI
import KeensInKeyCore

/// All tracks plus persistence to Application Support.
@Observable
final class LibraryStore {
    private(set) var tracks: [Track] = []
    var searchText = ""
    /// When set, the table only shows tracks harmonically compatible with this key.
    var keyFilter: MusicalKey?

    private var saveTask: Task<Void, Never>?
    private var index: [UUID: Int] = [:]

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("KeensInKey", isDirectory: true)
    }
    static var fileURL: URL { directory.appendingPathComponent("library.json") }

    init() {
        load()
    }

    // MARK: Access

    func track(_ id: UUID) -> Track? {
        guard let i = index[id], i < tracks.count, tracks[i].id == id else { return tracks.first { $0.id == id } }
        return tracks[i]
    }

    func tracks(_ ids: some Collection<UUID>) -> [Track] { ids.compactMap { track($0) } }

    func update(_ id: UUID, _ mutate: (inout Track) -> Void) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tracks[i])
        scheduleSave()
    }

    var filteredTracks: [Track] {
        var list = tracks
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.displayTitle.lowercased().contains(q) || $0.artist.lowercased().contains(q) || $0.fileName.lowercased().contains(q)
                    || ($0.key?.camelot.lowercased() == q) || ($0.key?.traditional.lowercased() == q)
            }
        }
        if let kf = keyFilter {
            list = list.filter { $0.key.map { kf.relation(to: $0).isCompatible } ?? false }
        }
        return list
    }

    // MARK: Mutation

    /// Adds files (folders are scanned recursively). Returns the ids of the new tracks.
    @discardableResult
    func add(urls: [URL]) -> [UUID] {
        let fm = FileManager.default
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let u as URL in e where AudioDecoder.isSupported(u) { files.append(u) }
                }
            } else if AudioDecoder.isSupported(url), fm.fileExists(atPath: url.path) {
                files.append(url)
            }
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let existing = Set(tracks.map(\.path))
        var newIds: [UUID] = []
        for f in files where !existing.contains(f.path) {
            let t = Track.make(url: f)
            tracks.append(t)
            newIds.append(t.id)
        }
        rebuildIndex()
        scheduleSave()
        // Read tags in the background.
        for id in newIds {
            Task.detached(priority: .utility) { [weak self] in
                guard let self, let track = await MainActor.run(body: { self.track(id) }) else { return }
                let tags = await TagService.read(track.url)
                let duration = AudioDecoder.duration(of: track.url)
                await MainActor.run {
                    self.update(id) { t in
                        t.existingTags = tags
                        if let title = tags.title, !title.isEmpty { t.title = title }
                        t.artist = tags.artist ?? ""
                        t.album = tags.album ?? ""
                        t.genre = tags.genre ?? ""
                        t.duration = duration
                    }
                }
            }
        }
        return newIds
    }

    func remove(ids: Set<UUID>) {
        tracks.removeAll { ids.contains($0.id) }
        rebuildIndex()
        scheduleSave()
    }

    func removeAll() {
        tracks.removeAll()
        rebuildIndex()
        scheduleSave()
    }

    func removeMissing() {
        tracks.removeAll { $0.isMissing }
        rebuildIndex()
        scheduleSave()
    }

    private func rebuildIndex() {
        index = [:]
        for (i, t) in tracks.enumerated() { index[t.id] = i }
    }

    // MARK: Persistence

    private struct Stored: Codable {
        var version: Int
        var tracks: [Track]
    }

    private func load() {
        guard let data = try? Data(contentsOf: LibraryStore.fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        tracks = stored.tracks.map { t in
            var t = t
            if t.status == .analyzing || t.status == .queued { t.status = t.result == nil ? .pending : .done }
            t.progress = t.result == nil ? 0 : 1
            return t
        }
        rebuildIndex()
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            self.saveNow()
        }
    }

    func saveNow() {
        do {
            try FileManager.default.createDirectory(at: LibraryStore.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            let data = try encoder.encode(Stored(version: 1, tracks: tracks))
            try data.write(to: LibraryStore.fileURL, options: .atomic)
        } catch {
            NSLog("Library save failed: \(error)")
        }
    }
}
