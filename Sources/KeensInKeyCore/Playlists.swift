import Foundation

// MARK: - Tags (secondary classification, rekordbox "My Tag" style)

public struct MusicTag: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public struct TagCategory: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var tags: [MusicTag]
    public init(id: UUID = UUID(), name: String, tags: [MusicTag] = []) { self.id = id; self.name = name; self.tags = tags }

    /// rekordbox-like defaults.
    public static var defaults: [TagCategory] {
        [
            TagCategory(name: "Genre", tags: ["House", "Techno", "Hip-Hop", "Pop", "Drum & Bass", "Disco"].map { MusicTag(name: $0) }),
            TagCategory(name: "Components", tags: ["Vocal", "Instrumental", "Acapella", "Remix", "Live"].map { MusicTag(name: $0) }),
            TagCategory(name: "Situation", tags: ["Warm-up", "Peak time", "Closing", "After-hours"].map { MusicTag(name: $0) }),
            TagCategory(name: "Mood", tags: ["Dark", "Uplifting", "Deep", "Groovy", "Euphoric"].map { MusicTag(name: $0) }),
        ]
    }
}

public enum TagMatch: String, Codable, CaseIterable, Sendable {
    case all, any
    public var displayName: String { self == .all ? "Match all" : "Match any" }
}

/// Active tag filter on a track list.
public struct TagFilter: Codable, Hashable, Sendable {
    public var tagIds: Set<UUID> = []
    public var match: TagMatch = .all
    public init(tagIds: Set<UUID> = [], match: TagMatch = .all) { self.tagIds = tagIds; self.match = match }
    public var isActive: Bool { !tagIds.isEmpty }

    public func matches(_ trackTags: Set<UUID>) -> Bool {
        guard isActive else { return true }
        switch match {
        case .all: return tagIds.isSubset(of: trackTags)
        case .any: return !tagIds.isDisjoint(with: trackTags)
        }
    }
}

// MARK: - Facts about a track used by rules (decoupled from the app's Track type)

public struct TrackFacts: Sendable {
    public var id: UUID
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String
    public var key: MusicalKey?
    public var bpm: Double?
    public var energy: Int?
    public var duration: Double?
    public var tagIds: Set<UUID>
    public var addedAt: Date
    public var analyzed: Bool

    public init(id: UUID, title: String, artist: String, album: String = "", genre: String = "", key: MusicalKey?, bpm: Double?, energy: Int?, duration: Double? = nil, tagIds: Set<UUID>, addedAt: Date = Date(), analyzed: Bool) {
        self.id = id; self.title = title; self.artist = artist; self.album = album; self.genre = genre
        self.key = key; self.bpm = bpm; self.energy = energy; self.duration = duration; self.tagIds = tagIds; self.addedAt = addedAt; self.analyzed = analyzed
    }
}

// MARK: - Smart playlist rules (Apple Music style)

public struct SmartRules: Codable, Hashable, Sendable {
    public var tags = TagFilter()
    /// Only tracks in these keys (any). Empty = any key.
    public var keys: Set<MusicalKey> = []
    /// Only tracks harmonically compatible with this key (same, ±1, relative).
    public var compatibleWith: MusicalKey?
    public var minBPM: Double?
    public var maxBPM: Double?
    public var minEnergy: Int?
    public var maxEnergy: Int?
    public var genreContains = ""
    public var textContains = ""
    public var analyzedOnly = true
    public var limit: Int?
    public var sort: SmartSort = .addedNewest

    public enum SmartSort: String, Codable, CaseIterable, Sendable, Identifiable {
        case addedNewest, addedOldest, title, artist, key, bpmAscending, bpmDescending, energyAscending, energyDescending
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .addedNewest: return "Date added (newest first)"
            case .addedOldest: return "Date added (oldest first)"
            case .title: return "Title"
            case .artist: return "Artist"
            case .key: return "Camelot key"
            case .bpmAscending: return "BPM ascending"
            case .bpmDescending: return "BPM descending"
            case .energyAscending: return "Energy ascending"
            case .energyDescending: return "Energy descending"
            }
        }
    }

    public init() {}

    public var isEmpty: Bool {
        !tags.isActive && keys.isEmpty && compatibleWith == nil && minBPM == nil && maxBPM == nil && minEnergy == nil && maxEnergy == nil
            && genreContains.isEmpty && textContains.isEmpty
    }

    public func matches(_ t: TrackFacts) -> Bool {
        if analyzedOnly && !t.analyzed { return false }
        if !tags.matches(t.tagIds) { return false }
        if !keys.isEmpty { guard let k = t.key, keys.contains(k) else { return false } }
        if let c = compatibleWith { guard let k = t.key, c.relation(to: k).isCompatible else { return false } }
        if let lo = minBPM { guard let b = t.bpm, b >= lo - 1e-9 else { return false } }
        if let hi = maxBPM { guard let b = t.bpm, b <= hi + 1e-9 else { return false } }
        if let lo = minEnergy { guard let e = t.energy, e >= lo else { return false } }
        if let hi = maxEnergy { guard let e = t.energy, e <= hi else { return false } }
        if !genreContains.isEmpty, t.genre.range(of: genreContains, options: .caseInsensitive) == nil { return false }
        if !textContains.isEmpty {
            let hay = "\(t.title) \(t.artist) \(t.album)"
            if hay.range(of: textContains, options: .caseInsensitive) == nil { return false }
        }
        return true
    }

    public func apply(to tracks: [TrackFacts]) -> [TrackFacts] {
        var out = tracks.filter(matches)
        switch sort {
        case .addedNewest: out.sort { $0.addedAt > $1.addedAt }
        case .addedOldest: out.sort { $0.addedAt < $1.addedAt }
        case .title: out.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: out.sort { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .key: out.sort { ($0.key.map { $0.camelotNumber * 2 + ($0.mode == .major ? 1 : 0) } ?? 99) < ($1.key.map { $0.camelotNumber * 2 + ($0.mode == .major ? 1 : 0) } ?? 99) }
        case .bpmAscending: out.sort { ($0.bpm ?? 0) < ($1.bpm ?? 0) }
        case .bpmDescending: out.sort { ($0.bpm ?? 0) > ($1.bpm ?? 0) }
        case .energyAscending: out.sort { ($0.energy ?? 0) < ($1.energy ?? 0) }
        case .energyDescending: out.sort { ($0.energy ?? 0) > ($1.energy ?? 0) }
        }
        if let limit, limit > 0 { out = Array(out.prefix(limit)) }
        return out
    }
}

// MARK: - Playlist tree (collections = folders, nested playlists, smart playlists)

public enum PlaylistKind: String, Codable, Sendable {
    case folder, playlist, smart
}

public struct PlaylistNode: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var emoji: String
    public var kind: PlaylistKind
    /// Manual playlists: ordered track ids.
    public var trackIds: [UUID]
    public var rules: SmartRules?
    public var children: [PlaylistNode]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, emoji: String = "", kind: PlaylistKind, trackIds: [UUID] = [], rules: SmartRules? = nil, children: [PlaylistNode] = [], createdAt: Date = Date()) {
        self.id = id; self.name = name; self.emoji = emoji; self.kind = kind
        self.trackIds = trackIds; self.rules = rules; self.children = children; self.createdAt = createdAt
    }

    public var displayName: String { emoji.isEmpty ? name : "\(emoji) \(name)" }
    public var isFolder: Bool { kind == .folder }

    /// Depth-first traversal.
    public func forEachNode(_ body: (PlaylistNode) -> Void) {
        body(self)
        for c in children { c.forEachNode(body) }
    }
}

/// Helpers for editing a forest of playlist nodes.
public enum PlaylistTree {
    public static func find(_ id: UUID, in nodes: [PlaylistNode]) -> PlaylistNode? {
        for n in nodes {
            if n.id == id { return n }
            if let f = find(id, in: n.children) { return f }
        }
        return nil
    }

    /// Path of ids from the root to `id` (inclusive), or nil.
    public static func path(to id: UUID, in nodes: [PlaylistNode]) -> [UUID]? {
        for n in nodes {
            if n.id == id { return [n.id] }
            if let p = path(to: id, in: n.children) { return [n.id] + p }
        }
        return nil
    }

    /// Applies `mutate` to the node with `id`. Returns true when found.
    @discardableResult
    public static func update(_ id: UUID, in nodes: inout [PlaylistNode], _ mutate: (inout PlaylistNode) -> Void) -> Bool {
        for i in nodes.indices {
            if nodes[i].id == id { mutate(&nodes[i]); return true }
            if update(id, in: &nodes[i].children, mutate) { return true }
        }
        return false
    }

    @discardableResult
    public static func remove(_ id: UUID, from nodes: inout [PlaylistNode]) -> PlaylistNode? {
        if let i = nodes.firstIndex(where: { $0.id == id }) { return nodes.remove(at: i) }
        for i in nodes.indices {
            if let r = remove(id, from: &nodes[i].children) { return r }
        }
        return nil
    }

    /// Inserts `node` under `parent` (nil = top level). Returns false when the parent does not exist or is not a folder/playlist.
    @discardableResult
    public static func insert(_ node: PlaylistNode, under parent: UUID?, in nodes: inout [PlaylistNode]) -> Bool {
        guard let parent else { nodes.append(node); return true }
        return update(parent, in: &nodes) { $0.children.append(node) }
    }

    /// Moves a node under a new parent (nil = top level). Refuses to move a node into itself.
    @discardableResult
    public static func move(_ id: UUID, under parent: UUID?, in nodes: inout [PlaylistNode]) -> Bool {
        if let parent, let p = path(to: parent, in: nodes), p.contains(id) { return false }
        guard let node = remove(id, from: &nodes) else { return false }
        if !insert(node, under: parent, in: &nodes) { nodes.append(node) }
        return true
    }

    /// Every track id referenced by the node (folders: union of descendants in order, without duplicates).
    public static func manualTrackIds(of node: PlaylistNode) -> [UUID] {
        var seen = Set<UUID>()
        var out: [UUID] = []
        func visit(_ n: PlaylistNode) {
            if n.kind == .playlist { for t in n.trackIds where seen.insert(t).inserted { out.append(t) } }
            for c in n.children { visit(c) }
        }
        visit(node)
        return out
    }

    /// Removes a track id from every manual playlist.
    public static func purgeTrack(_ trackId: UUID, from nodes: inout [PlaylistNode]) {
        for i in nodes.indices {
            nodes[i].trackIds.removeAll { $0 == trackId }
            purgeTrack(trackId, from: &nodes[i].children)
        }
    }

    public static func allNodes(_ nodes: [PlaylistNode]) -> [PlaylistNode] {
        var out: [PlaylistNode] = []
        for n in nodes { n.forEachNode { out.append($0) } }
        return out
    }
}

/// Resolves the tracks of any node given the library's track facts (used by the app and the exporters).
public enum PlaylistResolver {
    public static func trackIds(of node: PlaylistNode, facts: [UUID: TrackFacts], allFacts: [TrackFacts]) -> [UUID] {
        switch node.kind {
        case .playlist:
            return node.trackIds.filter { facts[$0] != nil }
        case .smart:
            return (node.rules ?? SmartRules()).apply(to: allFacts).map(\.id)
        case .folder:
            var seen = Set<UUID>()
            var out: [UUID] = []
            for c in node.children {
                for t in trackIds(of: c, facts: facts, allFacts: allFacts) where seen.insert(t).inserted { out.append(t) }
            }
            return out
        }
    }
}
