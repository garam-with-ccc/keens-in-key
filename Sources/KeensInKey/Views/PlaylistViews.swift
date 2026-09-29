import SwiftUI
import KeensInKeyCore

// MARK: - Playlist header (shown above the track table when a collection / playlist is selected)

struct PlaylistHeader: View {
    let node: PlaylistNode
    let tracks: [Track]
    @Environment(AppState.self) private var state
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let total = tracks.reduce(0.0) { $0 + ($1.result?.duration ?? $1.duration ?? 0) }
        let path = PlaylistTree.path(to: node.id, in: library.collections)?.dropLast().compactMap { library.node($0)?.displayName } ?? []
        HStack(alignment: .center, spacing: 14) {
            Text(node.emoji.isEmpty ? (node.kind == .folder ? "📁" : (node.kind == .smart ? "✨" : "🎵")) : node.emoji)
                .font(.system(size: 34))
                .frame(width: 52, height: 52)
                .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                if !path.isEmpty {
                    Text(path.joined(separator: " › ")).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                }
                Text(node.name).font(.system(size: 20, weight: .bold))
                HStack(spacing: 8) {
                    Text(node.kind == .folder ? "Collection" : (node.kind == .smart ? "Smart playlist" : "Playlist"))
                    Text("·")
                    Text("\(tracks.count) track\(tracks.count == 1 ? "" : "s")")
                    Text("·")
                    Text(total.timeString)
                    if node.kind == .smart, let r = node.rules { Text("·"); Text(summary(r)).lineLimit(1) }
                }
                .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if node.kind == .smart {
                Button { state.editingSmartRules = node.id } label: { Label("Edit Rules", systemImage: "slider.horizontal.3") }.buttonStyle(ToolbarButtonStyle())
            }
            Button { state.editingNode = node.id } label: { Label("Rename", systemImage: "pencil") }.buttonStyle(ToolbarButtonStyle())
            if node.kind != .smart {
                Button { state.newNodeRequest = .init(kind: .playlist, parent: node.id) } label: { Label("New Playlist", systemImage: "plus") }.buttonStyle(ToolbarButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.background)
    }

    private func summary(_ r: SmartRules) -> String {
        var parts: [String] = []
        if r.tags.isActive { parts.append("\(r.tags.tagIds.count) tag\(r.tags.tagIds.count == 1 ? "" : "s") (\(r.tags.match == .all ? "all" : "any"))") }
        if let c = r.compatibleWith { parts.append("compatible with \(c.camelot)") }
        if !r.keys.isEmpty { parts.append("keys \(r.keys.map(\.camelot).sorted().joined(separator: ", "))") }
        if r.minBPM != nil || r.maxBPM != nil { parts.append("BPM \(r.minBPM.map { Int($0) }.map(String.init) ?? "…")–\(r.maxBPM.map { Int($0) }.map(String.init) ?? "…")") }
        if r.minEnergy != nil || r.maxEnergy != nil { parts.append("energy \(r.minEnergy.map(String.init) ?? "…")–\(r.maxEnergy.map(String.init) ?? "…")") }
        if !r.genreContains.isEmpty { parts.append("genre ~ \(r.genreContains)") }
        if !r.textContains.isEmpty { parts.append("text ~ \(r.textContains)") }
        return parts.isEmpty ? "all analyzed tracks" : parts.joined(separator: ", ")
    }
}

// MARK: - Tag filter bar

struct TagFilterBar: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        @Bindable var library = library
        if !library.allTags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Image(systemName: "tag").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    ForEach(library.tagCategories) { cat in
                        ForEach(cat.tags) { tag in
                            let on = library.tagFilter.tagIds.contains(tag.id)
                            Button {
                                if on { library.tagFilter.tagIds.remove(tag.id) } else { library.tagFilter.tagIds.insert(tag.id) }
                            } label: {
                                Text(tag.name)
                                    .font(.system(size: 11, weight: on ? .semibold : .regular))
                                    .foregroundStyle(on ? Color.black.opacity(0.85) : Theme.text)
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(on ? Theme.teal : Theme.panelRaised, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Theme.border))
                            }
                            .buttonStyle(.plain)
                            .help(cat.name)
                        }
                        if cat.id != library.tagCategories.last?.id { Divider().frame(height: 14) }
                    }
                    if library.tagFilter.isActive {
                        Picker("", selection: $library.tagFilter.match) {
                            ForEach(TagMatch.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 150)
                        Button { library.tagFilter.tagIds.removeAll() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
            }
            .background(Theme.panel)
        }
    }
}

// MARK: - Tag inspector (assign tags to the selected tracks)

struct TagPanel: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var state
    @State private var newTagText: [UUID: String] = [:]

    var body: some View {
        let sel = state.selection
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TAGS").font(.system(size: 10.5, weight: .bold)).tracking(1.1).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button { state.showTagManager = true } label: { Image(systemName: "gearshape").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help("Manage tags")
                Button { state.showTagPanel = false } label: { Image(systemName: "xmark").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            }
            if sel.isEmpty {
                Text("Select tracks to tag them.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            } else {
                Text("\(sel.count) track\(sel.count == 1 ? "" : "s") selected").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(library.tagCategories) { cat in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(cat.name).font(.system(size: 12, weight: .semibold))
                            FlowLayout(spacing: 6) {
                                ForEach(cat.tags) { tag in
                                    let count = library.tagCount(tag.id, in: sel)
                                    let all = !sel.isEmpty && count == sel.count
                                    let some = count > 0 && !all
                                    Button {
                                        library.setTag(tag.id, on: sel, enabled: !all)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: all ? "checkmark.circle.fill" : (some ? "minus.circle.fill" : "circle")).font(.system(size: 11))
                                            Text(tag.name).font(.system(size: 11.5))
                                        }
                                        .foregroundStyle(all ? Color.black.opacity(0.85) : Theme.text)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(all ? Theme.teal : (some ? Theme.teal.opacity(0.35) : Theme.panelRaised), in: Capsule())
                                        .overlay(Capsule().strokeBorder(Theme.border))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(sel.isEmpty)
                                }
                            }
                            HStack(spacing: 4) {
                                TextField("Add tag…", text: Binding(get: { newTagText[cat.id] ?? "" }, set: { newTagText[cat.id] = $0 }))
                                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                                    .onSubmit { addTag(cat) }
                                Button { addTag(cat) } label: { Image(systemName: "plus.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                                    .disabled((newTagText[cat.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 250)
        .background(Theme.panel)
    }

    private func addTag(_ cat: TagCategory) {
        let text = (newTagText[cat.id] ?? "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let t = library.addTag(text, to: cat.id), !state.selection.isEmpty {
            library.setTag(t.id, on: state.selection, enabled: true)
        }
        newTagText[cat.id] = ""
    }
}

/// Simple wrapping layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - Emoji picker

struct EmojiPicker: View {
    @Binding var emoji: String
    static let choices = ["🎧", "🎵", "🔥", "💎", "🌙", "☀️", "🌊", "⚡️", "💜", "❤️", "💚", "💙", "🖤", "🥂", "💍", "🎉", "🏝️", "🏠", "🚀", "🎸", "🥁", "🎹", "🎤", "🕺", "💃", "✨", "🌈", "🍹", "🎄", "🎃", "📀", "📁"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Emoji").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                TextField("Any emoji", text: $emoji).textFieldStyle(.roundedBorder).frame(width: 90)
                    .onChange(of: emoji) { _, v in if v.count > 2 { emoji = String(v.suffix(2)) } }
                Button("None") { emoji = "" }.buttonStyle(ToolbarButtonStyle())
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30)), count: 11), spacing: 4) {
                ForEach(EmojiPicker.choices, id: \.self) { e in
                    Button { emoji = e } label: {
                        Text(e).font(.system(size: 17)).frame(width: 28, height: 28)
                            .background(emoji == e ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Sheets

struct NewNodeSheet: View {
    let request: AppState.NewNodeRequest
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var emoji = ""
    @State private var parent: UUID?
    @State private var addSelection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.kind == .folder ? "New Collection" : (request.kind == .smart ? "New Smart Playlist" : "New Playlist")).font(.system(size: 16, weight: .bold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            EmojiPicker(emoji: $emoji)
            if request.kind != .folder {
                let folders = PlaylistTree.allNodes(library.collections).filter { $0.kind != .smart }
                Picker("Inside", selection: $parent) {
                    Text("Top level").tag(UUID?.none)
                    ForEach(folders) { f in Text(f.displayName).tag(UUID?.some(f.id)) }
                }
                if request.kind == .playlist, !state.selection.isEmpty {
                    Toggle("Add the \(state.selection.count) selected track\(state.selection.count == 1 ? "" : "s")", isOn: $addSelection).toggleStyle(.checkbox)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { parent = request.parent; addSelection = request.kind == .playlist && !state.selection.isEmpty }
    }

    private func create() {
        let node = library.createNode(name: name.trimmingCharacters(in: .whitespaces), emoji: emoji, kind: request.kind,
                                      under: request.kind == .folder ? nil : parent,
                                      trackIds: addSelection ? Array(state.selection) : [])
        state.playlistSelection = node.id
        state.page = .analyze
        if request.kind == .smart { state.editingSmartRules = node.id }
        dismiss()
    }
}

struct EditNodeSheet: View {
    let nodeId: UUID
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var emoji = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename").font(.system(size: 16, weight: .bold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            EmojiPicker(emoji: $emoji)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    library.updateNode(nodeId) { $0.name = name.trimmingCharacters(in: .whitespaces); $0.emoji = emoji }
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { if let n = library.node(nodeId) { name = n.name; emoji = n.emoji } }
    }
}

struct SmartRulesSheet: View {
    let nodeId: UUID
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var rules = SmartRules()
    @State private var useBPM = false
    @State private var useEnergy = false
    @State private var useCompatible = false
    @State private var useLimit = false

    var body: some View {
        let matches = rules.apply(to: library.allFacts).count
        VStack(alignment: .leading, spacing: 12) {
            Text("Smart Playlist Rules").font(.system(size: 16, weight: .bold))
            Text("Tracks matching all of the rules below are included automatically.").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Tags").font(.system(size: 12, weight: .semibold))
                    Picker("", selection: $rules.tags.match) { ForEach(TagMatch.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 150)
                }
                ForEach(library.tagCategories) { cat in
                    HStack(alignment: .top, spacing: 6) {
                        Text(cat.name).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .trailing)
                        FlowLayout(spacing: 5) {
                            ForEach(cat.tags) { tag in
                                let on = rules.tags.tagIds.contains(tag.id)
                                Button { if on { rules.tags.tagIds.remove(tag.id) } else { rules.tags.tagIds.insert(tag.id) } } label: {
                                    Text(tag.name).font(.system(size: 11, weight: on ? .semibold : .regular))
                                        .foregroundStyle(on ? Color.black.opacity(0.85) : Theme.text)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(on ? Theme.teal : Theme.panelRaised, in: Capsule())
                                        .overlay(Capsule().strokeBorder(Theme.border))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Toggle("Compatible with key", isOn: $useCompatible).toggleStyle(.checkbox)
                Picker("", selection: Binding(get: { rules.compatibleWith ?? MusicalKey.parse("8A")! }, set: { rules.compatibleWith = $0 })) {
                    ForEach(MusicalKey.allKeys, id: \.self) { k in Text("\(k.camelot)  \(k.traditional)").tag(k) }
                }.labelsHidden().frame(width: 130).disabled(!useCompatible)
                Spacer()
                Toggle("Analyzed tracks only", isOn: $rules.analyzedOnly).toggleStyle(.checkbox)
            }
            HStack(spacing: 10) {
                Toggle("BPM", isOn: $useBPM).toggleStyle(.checkbox)
                TextField("min", value: Binding(get: { rules.minBPM ?? 120 }, set: { rules.minBPM = $0 }), format: .number).frame(width: 60).disabled(!useBPM)
                Text("to").foregroundStyle(Theme.textSecondary)
                TextField("max", value: Binding(get: { rules.maxBPM ?? 130 }, set: { rules.maxBPM = $0 }), format: .number).frame(width: 60).disabled(!useBPM)
                Spacer().frame(width: 20)
                Toggle("Energy", isOn: $useEnergy).toggleStyle(.checkbox)
                Stepper(value: Binding(get: { rules.minEnergy ?? 1 }, set: { rules.minEnergy = $0 }), in: 1...10) { Text("\(rules.minEnergy ?? 1)").frame(width: 20) }.disabled(!useEnergy)
                Text("to").foregroundStyle(Theme.textSecondary)
                Stepper(value: Binding(get: { rules.maxEnergy ?? 10 }, set: { rules.maxEnergy = $0 }), in: 1...10) { Text("\(rules.maxEnergy ?? 10)").frame(width: 20) }.disabled(!useEnergy)
            }
            HStack(spacing: 10) {
                Text("Genre contains").font(.system(size: 12))
                TextField("e.g. house", text: $rules.genreContains).textFieldStyle(.roundedBorder).frame(width: 140)
                Text("Title / artist contains").font(.system(size: 12))
                TextField("text", text: $rules.textContains).textFieldStyle(.roundedBorder).frame(width: 140)
            }
            HStack(spacing: 10) {
                Text("Sort by").font(.system(size: 12))
                Picker("", selection: $rules.sort) { ForEach(SmartRules.SmartSort.allCases) { Text($0.displayName).tag($0) } }.labelsHidden().frame(width: 220)
                Toggle("Limit to", isOn: $useLimit).toggleStyle(.checkbox)
                Stepper(value: Binding(get: { rules.limit ?? 25 }, set: { rules.limit = $0 }), in: 1...500, step: 5) { Text("\(rules.limit ?? 25) tracks").frame(width: 80, alignment: .leading) }.disabled(!useLimit)
            }
            Divider()
            HStack {
                Text("\(matches) matching track\(matches == 1 ? "" : "s")").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var r = rules
                    if !useBPM { r.minBPM = nil; r.maxBPM = nil }
                    if !useEnergy { r.minEnergy = nil; r.maxEnergy = nil }
                    if !useCompatible { r.compatibleWith = nil }
                    if !useLimit { r.limit = nil }
                    library.updateNode(nodeId) { $0.rules = r }
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear {
            if let n = library.node(nodeId), let r = n.rules {
                rules = r
                useBPM = r.minBPM != nil || r.maxBPM != nil
                useEnergy = r.minEnergy != nil || r.maxEnergy != nil
                useCompatible = r.compatibleWith != nil
                useLimit = r.limit != nil
            }
        }
    }
}

struct TagManagerSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var newCategory = ""
    @State private var newTag: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage Tags").font(.system(size: 16, weight: .bold))
            Text("Categories group your tags (like rekordbox's My Tag). Renaming keeps the tag on every track; deleting removes it everywhere.").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(library.tagCategories) { cat in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("Category", text: Binding(get: { cat.name }, set: { library.renameCategory(cat.id, to: $0) })).textFieldStyle(.roundedBorder).font(.system(size: 12, weight: .semibold)).frame(width: 180)
                                Spacer()
                                Button(role: .destructive) { library.deleteCategory(cat.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Theme.danger)
                            }
                            FlowLayout(spacing: 6) {
                                ForEach(cat.tags) { tag in
                                    HStack(spacing: 4) {
                                        TextField("Tag", text: Binding(get: { tag.name }, set: { library.renameTag(tag.id, to: $0) })).textFieldStyle(.plain).font(.system(size: 11.5)).frame(width: max(40, CGFloat(tag.name.count) * 7 + 10))
                                        Button { library.deleteTag(tag.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Theme.panelRaised, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Theme.border))
                                }
                                HStack(spacing: 4) {
                                    TextField("New tag", text: Binding(get: { newTag[cat.id] ?? "" }, set: { newTag[cat.id] = $0 })).textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(width: 110)
                                        .onSubmit { _ = library.addTag(newTag[cat.id] ?? "", to: cat.id); newTag[cat.id] = "" }
                                    Button { _ = library.addTag(newTag[cat.id] ?? "", to: cat.id); newTag[cat.id] = "" } label: { Image(systemName: "plus.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .padding(10)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    HStack {
                        TextField("New category", text: $newCategory).textFieldStyle(.roundedBorder).frame(width: 180)
                            .onSubmit { addCategory() }
                        Button("Add Category") { addCategory() }.buttonStyle(ToolbarButtonStyle()).disabled(newCategory.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .frame(minHeight: 300, maxHeight: 460)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func addCategory() {
        let n = newCategory.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        _ = library.addCategory(n)
        newCategory = ""
    }
}

// MARK: - Song Info editor (Mixed In Key 11 "Song Info")

struct SongInfoEditor: View {
    let track: Track
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var state
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var genre = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Song info")
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                GridRow { label("Title"); TextField("Title", text: $title).textFieldStyle(.roundedBorder) }
                GridRow { label("Artist"); TextField("Artist", text: $artist).textFieldStyle(.roundedBorder) }
                GridRow { label("Album"); TextField("Album", text: $album).textFieldStyle(.roundedBorder) }
                GridRow { label("Genre"); TextField("Genre", text: $genre).textFieldStyle(.roundedBorder) }
            }
            .font(.system(size: 11.5))
            HStack {
                Spacer()
                Button { save() } label: { Label(saving ? "Saving…" : "Save to File", systemImage: "square.and.arrow.down") }
                    .buttonStyle(ToolbarButtonStyle(prominent: true)).disabled(saving || !dirty)
            }
        }
        .onAppear(perform: load)
        .onChange(of: track.id) { _, _ in load() }
    }

    private var dirty: Bool {
        title != track.displayTitle || artist != track.artist || album != track.album || genre != track.genre
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).frame(width: 44, alignment: .trailing)
    }

    private func load() {
        title = track.displayTitle; artist = track.artist; album = track.album; genre = track.genre
    }

    private func save() {
        saving = true
        let fields = TagFields(title: title, artist: artist, album: album, genre: genre)
        let id = track.id, url = track.url
        Task { @MainActor in
            do {
                _ = try await TagService.write(fields, to: url)
                library.update(id) { t in t.title = title; t.artist = artist; t.album = album; t.genre = genre
                    t.existingTags.title = title; t.existingTags.artist = artist; t.existingTags.album = album; t.existingTags.genre = genre }
            } catch {
                state.showAlert("Could not save", error.localizedDescription)
            }
            saving = false
        }
    }
}
