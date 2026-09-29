import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KeensInKeyCore

struct SidebarView: View {
    @Environment(AppState.self) private var state
    @Environment(AnalysisController.self) private var analysis
    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Keens In Key").font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("Harmonic mixing").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            .padding(.bottom, 18)

            ForEach(Page.allCases) { page in
                Button {
                    state.page = page
                    if page == .analyze { state.playlistSelection = nil }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: page.icon)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 20)
                        Text(page == .analyze ? "All Tracks" : page.title).font(.system(size: 13, weight: isActive(page) ? .semibold : .regular))
                        Spacer()
                        if page == .analyze {
                            Text("\(library.tracks.count)").font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .foregroundStyle(isActive(page) ? Theme.accent : Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(isActive(page) ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
            }

            HStack {
                Text("COLLECTIONS").font(.system(size: 10.5, weight: .bold)).tracking(1.1).foregroundStyle(Theme.textSecondary)
                Spacer()
                Menu {
                    Button("New Collection…") { state.newNodeRequest = .init(kind: .folder, parent: nil) }
                    Button("New Playlist…") { state.newNodeRequest = .init(kind: .playlist, parent: currentFolderId) }
                    Button("New Smart Playlist…") { state.newNodeRequest = .init(kind: .smart, parent: currentFolderId) }
                    Divider()
                    Button("Manage Tags…") { state.showTagManager = true }
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textSecondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("New collection, playlist or smart playlist")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if library.collections.isEmpty {
                        Text("Create a collection to group playlists.\nDrag tracks from the list onto a playlist.")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 20).padding(.vertical, 6)
                    }
                    ForEach(library.collections) { node in
                        PlaylistRow(node: node, depth: 0)
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 6) {
                if analysis.isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing \(analysis.completed)/\(analysis.total)").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    ProgressView(value: Double(analysis.completed), total: Double(max(1, analysis.total))).tint(Theme.accent)
                } else {
                    let done = library.tracks.filter { $0.result != nil }.count
                    Text("\(library.tracks.count) tracks · \(done) analyzed").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                Text("v\(AppInfo.version)").font(.system(size: 10)).foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
            .padding(16)
        }
        .frame(width: 210)
        .background(Theme.sidebar)
    }

    private func isActive(_ page: Page) -> Bool {
        state.page == page && (page != .analyze || state.playlistSelection == nil)
    }

    /// The collection to create new playlists in: the selected node's collection, else the first collection.
    private var currentFolderId: UUID? {
        if let sel = state.playlistSelection, let path = PlaylistTree.path(to: sel, in: library.collections), let first = path.first {
            return first
        }
        return library.collections.first?.id
    }
}

/// One row of the collection tree (recursive).
private struct PlaylistRow: View {
    let node: PlaylistNode
    let depth: Int
    @Environment(AppState.self) private var state
    @Environment(LibraryStore.self) private var library
    @State private var expanded = true
    @State private var targeted = false

    private var selected: Bool { state.page == .analyze && state.playlistSelection == node.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if !node.children.isEmpty {
                    Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(Theme.textSecondary).frame(width: 12)
                    }.buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 12)
                }
                Text(node.emoji.isEmpty ? iconFallback : node.emoji).font(.system(size: 13)).frame(width: 18)
                Text(node.name).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer()
                if node.kind != .folder {
                    Text("\(library.tracks(in: node.id).count)").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                }
            }
            .foregroundStyle(selected ? Theme.accent : Theme.text)
            .padding(.leading, CGFloat(depth) * 14 + 6)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(targeted ? Theme.accent.opacity(0.35) : (selected ? Theme.accentSoft : Color.clear))
            )
            .contentShape(Rectangle())
            .onTapGesture {
                state.playlistSelection = node.id
                state.page = .analyze
            }
            .onDrop(of: [UTType.plainText], isTargeted: $targeted) { providers in
                handleDrop(providers)
            }
            .contextMenu {
                if node.kind == .folder || node.kind == .playlist {
                    Button("New Playlist Inside…") { state.newNodeRequest = .init(kind: .playlist, parent: node.id) }
                    Button("New Smart Playlist Inside…") { state.newNodeRequest = .init(kind: .smart, parent: node.id) }
                    Divider()
                }
                Button("Rename / Emoji…") { state.editingNode = node.id }
                if node.kind == .smart { Button("Edit Rules…") { state.editingSmartRules = node.id } }
                if let parentMenu = moveTargets() { parentMenu }
                Divider()
                Button("Duplicate") {
                    var copy = renumber(node)
                    copy.name += " copy"
                    let parent = PlaylistTree.path(to: node.id, in: library.collections)?.dropLast().last
                    library.insertNode(copy, under: parent)
                }
                Button("Delete", role: .destructive) {
                    if state.playlistSelection == node.id { state.playlistSelection = nil }
                    library.deleteNode(node.id)
                }
            }
            if expanded {
                ForEach(node.children) { child in
                    PlaylistRow(node: child, depth: depth + 1)
                }
            }
        }
    }

    private var iconFallback: String {
        switch node.kind {
        case .folder: return "📁"
        case .playlist: return "🎵"
        case .smart: return "✨"
        }
    }

    private func renumber(_ n: PlaylistNode) -> PlaylistNode {
        var c = n
        c.id = UUID()
        c.children = c.children.map(renumber)
        return c
    }

    private func moveTargets() -> AnyView? {
        let folders = PlaylistTree.allNodes(library.collections).filter { $0.kind == .folder && $0.id != node.id }
        if folders.isEmpty && depth == 0 { return nil }
        return AnyView(Menu("Move To") {
            Button("Top level") { library.moveNode(node.id, under: nil) }
            ForEach(folders) { f in
                Button(f.displayName) { library.moveNode(node.id, under: f.id) }
            }
        })
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard node.kind == .playlist else { return false }
        var ids: [UUID] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                if let s = obj as? String {
                    for part in s.split(separator: ",") { if let u = UUID(uuidString: String(part)) { ids.append(u) } }
                }
                group.leave()
            }
        }
        let target = node.id
        group.notify(queue: .main) {
            guard !ids.isEmpty else { return }
            library.add(trackIds: ids, to: target)
        }
        return true
    }
}
