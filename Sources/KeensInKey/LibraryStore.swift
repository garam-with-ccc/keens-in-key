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
    /// Collections (folders) with nested playlists and smart playlists.
    private(set) var collections: [PlaylistNode] = []
    /// Tag categories for secondary classification.
    private(set) var tagCategories: [TagCategory] = TagCategory.defaults
    /// Active tag filter for the track list.
    var tagFilter = TagFilter()

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

    var filteredTracks: [Track] { filtered(tracks) }

    /// Applies search, key filter and tag filter to a track list.
    func filtered(_ source: [Track]) -> [Track] {
        var list = source
        if tagFilter.isActive { list = list.filter { tagFilter.matches($0.tagIds) } }
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
        for id in ids { PlaylistTree.purgeTrack(id, from: &collections) }
        rebuildIndex()
        scheduleSave()
    }

    func removeAll() {
        tracks.removeAll()
        for i in collections.indices { purgeAll(&collections[i]) }
        rebuildIndex()
        scheduleSave()
    }

    private func purgeAll(_ node: inout PlaylistNode) {
        node.trackIds.removeAll()
        for i in node.children.indices { purgeAll(&node.children[i]) }
    }

    // MARK: Collections & playlists

    var allFacts: [TrackFacts] { tracks.map(\.facts) }

    func node(_ id: UUID) -> PlaylistNode? { PlaylistTree.find(id, in: collections) }

    /// Tracks of a collection / playlist / smart playlist, in playlist order (before search/tag filtering).
    func tracks(in nodeId: UUID) -> [Track] {
        guard let n = node(nodeId) else { return [] }
        let facts = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0.facts) })
        return PlaylistResolver.trackIds(of: n, facts: facts, allFacts: allFacts).compactMap { track($0) }
    }

    @discardableResult
    func createNode(name: String, emoji: String = "", kind: PlaylistKind, under parent: UUID? = nil, rules: SmartRules? = nil, trackIds: [UUID] = []) -> PlaylistNode {
        let node = PlaylistNode(name: name, emoji: emoji, kind: kind, trackIds: trackIds, rules: kind == .smart ? (rules ?? SmartRules()) : nil)
        PlaylistTree.insert(node, under: parent, in: &collections)
        scheduleSave()
        return node
    }

    /// Inserts an already built node (e.g. a duplicate) under `parent` (nil = top level).
    func insertNode(_ node: PlaylistNode, under parent: UUID?) {
        if !PlaylistTree.insert(node, under: parent, in: &collections) { collections.append(node) }
        scheduleSave()
    }

    func updateNode(_ id: UUID, _ mutate: (inout PlaylistNode) -> Void) {
        PlaylistTree.update(id, in: &collections, mutate)
        scheduleSave()
    }

    func deleteNode(_ id: UUID) {
        PlaylistTree.remove(id, from: &collections)
        scheduleSave()
    }

    func moveNode(_ id: UUID, under parent: UUID?) {
        PlaylistTree.move(id, under: parent, in: &collections)
        scheduleSave()
    }

    /// Adds tracks to a manual playlist (ignores duplicates). Returns how many were added.
    @discardableResult
    func add(trackIds ids: [UUID], to playlistId: UUID) -> Int {
        var added = 0
        updateNode(playlistId) { n in
            guard n.kind == .playlist else { return }
            for id in ids where !n.trackIds.contains(id) && track(id) != nil { n.trackIds.append(id); added += 1 }
        }
        return added
    }

    func remove(trackIds ids: Set<UUID>, from playlistId: UUID) {
        updateNode(playlistId) { n in n.trackIds.removeAll { ids.contains($0) } }
    }

    func move(trackId: UUID, in playlistId: UUID, by offset: Int) {
        updateNode(playlistId) { n in
            guard let i = n.trackIds.firstIndex(of: trackId) else { return }
            let j = max(0, min(n.trackIds.count - 1, i + offset))
            guard i != j else { return }
            let t = n.trackIds.remove(at: i)
            n.trackIds.insert(t, at: j)
        }
    }

    /// Manual playlists (not folders / smart) in tree order, with their collection path for menus.
    var manualPlaylists: [(node: PlaylistNode, path: String)] {
        var out: [(PlaylistNode, String)] = []
        func visit(_ n: PlaylistNode, _ prefix: String) {
            let label = prefix.isEmpty ? n.displayName : "\(prefix) › \(n.displayName)"
            if n.kind == .playlist { out.append((n, label)) }
            for c in n.children { visit(c, n.kind == .folder || n.kind == .playlist ? label : prefix) }
        }
        for n in collections { visit(n, "") }
        return out
    }

    // MARK: Tags

    var allTags: [(category: TagCategory, tag: MusicTag)] {
        tagCategories.flatMap { c in c.tags.map { (c, $0) } }
    }

    func tag(_ id: UUID) -> MusicTag? { allTags.first { $0.tag.id == id }?.tag }

    @discardableResult
    func addCategory(_ name: String) -> TagCategory {
        let c = TagCategory(name: name)
        tagCategories.append(c)
        scheduleSave()
        return c
    }

    func renameCategory(_ id: UUID, to name: String) {
        if let i = tagCategories.firstIndex(where: { $0.id == id }) { tagCategories[i].name = name; scheduleSave() }
    }

    func deleteCategory(_ id: UUID) {
        guard let i = tagCategories.firstIndex(where: { $0.id == id }) else { return }
        let ids = Set(tagCategories[i].tags.map(\.id))
        tagCategories.remove(at: i)
        for t in tracks.indices { tracks[t].tagIds.subtract(ids) }
        tagFilter.tagIds.subtract(ids)
        scheduleSave()
    }

    @discardableResult
    func addTag(_ name: String, to categoryId: UUID) -> MusicTag? {
        guard let i = tagCategories.firstIndex(where: { $0.id == categoryId }) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let existing = tagCategories[i].tags.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) { return existing }
        let t = MusicTag(name: trimmed)
        tagCategories[i].tags.append(t)
        scheduleSave()
        return t
    }

    func renameTag(_ id: UUID, to name: String) {
        for i in tagCategories.indices {
            if let j = tagCategories[i].tags.firstIndex(where: { $0.id == id }) { tagCategories[i].tags[j].name = name; scheduleSave(); return }
        }
    }

    func deleteTag(_ id: UUID) {
        for i in tagCategories.indices { tagCategories[i].tags.removeAll { $0.id == id } }
        for t in tracks.indices { tracks[t].tagIds.remove(id) }
        tagFilter.tagIds.remove(id)
        scheduleSave()
    }

    func setTag(_ tagId: UUID, on trackIds: Set<UUID>, enabled: Bool) {
        for i in tracks.indices where trackIds.contains(tracks[i].id) {
            if enabled { tracks[i].tagIds.insert(tagId) } else { tracks[i].tagIds.remove(tagId) }
        }
        scheduleSave()
    }

    /// How many of the given tracks carry the tag.
    func tagCount(_ tagId: UUID, in trackIds: Set<UUID>) -> Int {
        tracks.filter { trackIds.contains($0.id) && $0.tagIds.contains(tagId) }.count
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
        var collections: [PlaylistNode]?
        var tagCategories: [TagCategory]?
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
        collections = stored.collections ?? []
        if let cats = stored.tagCategories { tagCategories = cats }
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
            let data = try encoder.encode(Stored(version: 2, tracks: tracks, collections: collections, tagCategories: tagCategories))
            try data.write(to: LibraryStore.fileURL, options: .atomic)
        } catch {
            NSLog("Library save failed: \(error)")
        }
    }
}
