import SwiftUI
import KeensInKeyCore

/// Mirrors Mixed In Key's "Personalize" tab: how results are written into files.
struct PersonalizeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppState.self) private var state
    @Environment(LibraryStore.self) private var library
    @Environment(AnalysisController.self) private var analysis

    private var sampleTrack: Track? {
        state.primarySelection.flatMap { library.track($0) } ?? library.tracks.first { $0.result != nil }
    }

    var body: some View {
        @Bindable var settings = settings
        let o = settings.tagOptions
        SnapshotScroll {
            VStack(alignment: .leading, spacing: 16) {
                Text("Personalize").font(.system(size: 20, weight: .bold))
                Text("Choose how Keens In Key writes key, energy and BPM results into your music files. Tags are read by rekordbox, Serato, Traktor, Engine DJ and iTunes/Music.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Key notation")
                        ForEach(KeyNotation.allCases) { n in
                            Button {
                                settings.tagOptions.notation = n
                                settings.displayNotation = n
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: o.notation == n ? "largecircle.fill.circle" : "circle").foregroundStyle(o.notation == n ? Theme.accent : Theme.textSecondary)
                                    Text(n.displayName).font(.system(size: 13))
                                    Spacer()
                                    HStack(spacing: 4) {
                                        ForEach([MusicalKey.parse("8A")!, MusicalKey.parse("8B")!, MusicalKey.parse("3A")!], id: \.self) { k in
                                            KeyBadge(key: k, notation: n, size: 10.5)
                                        }
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Where to write the results")
                        Toggle(isOn: $settings.tagOptions.writeInitialKey) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Initial Key tag").font(.system(size: 13, weight: .medium))
                                Text("TKEY (MP3/AIFF/WAV) · INITIALKEY (FLAC) · ----:com.apple.iTunes:initialkey (M4A)").font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        Divider()
                        Toggle(isOn: $settings.tagOptions.writeComment) {
                            Text("Comment field").font(.system(size: 13, weight: .medium))
                        }
                        HStack(spacing: 10) {
                            Text("Format").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 60, alignment: .trailing)
                            TextField("{key} - Energy {energy}", text: $settings.tagOptions.commentFormat).textFieldStyle(.roundedBorder).frame(width: 260)
                            Picker("", selection: $settings.tagOptions.commentMode) {
                                ForEach(CommentMode.allCases) { m in Text(m.displayName).tag(m) }
                            }
                            .labelsHidden().frame(width: 230)
                        }
                        .disabled(!o.writeComment)
                        Text("Tokens: {key} {energy} {bpm} {camelot} {openkey} {traditional} {title} {artist}").font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary).padding(.leading, 70)
                        Divider()
                        Toggle(isOn: $settings.tagOptions.writeGrouping) {
                            Text("Grouping field").font(.system(size: 13, weight: .medium))
                        }
                        HStack(spacing: 10) {
                            Text("Format").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 60, alignment: .trailing)
                            TextField("{key}", text: $settings.tagOptions.groupingFormat).textFieldStyle(.roundedBorder).frame(width: 260)
                        }
                        .disabled(!o.writeGrouping)
                        Divider()
                        Toggle(isOn: $settings.tagOptions.writeBPM) {
                            Text("BPM tag").font(.system(size: 13, weight: .medium))
                        }
                        HStack(spacing: 10) {
                            Text("Decimals").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 60, alignment: .trailing)
                            Picker("", selection: $settings.tagOptions.bpmDecimals) {
                                Text("128").tag(0); Text("128.0").tag(1); Text("128.00").tag(2)
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 200)
                            Text("(M4A always stores a whole number)").font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                        }
                        .disabled(!o.writeBPM)
                        Divider()
                        Toggle(isOn: $settings.tagOptions.writeEnergyTag) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Energy Level tag").font(.system(size: 13, weight: .medium))
                                Text("TXXX:ENERGYLEVEL / ENERGYLEVEL, 1–10").font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        Divider()
                        Toggle(isOn: $settings.tagOptions.prefixTitle) {
                            Text("Add key to the song title").font(.system(size: 13, weight: .medium))
                        }
                        HStack(spacing: 10) {
                            Text("Format").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 60, alignment: .trailing)
                            TextField("{key} - {title}", text: $settings.tagOptions.titleFormat).textFieldStyle(.roundedBorder).frame(width: 260)
                        }
                        .disabled(!o.prefixTitle)
                        Divider()
                        Toggle(isOn: $settings.tagOptions.renameFile) {
                            Text("Rename the file").font(.system(size: 13, weight: .medium))
                        }
                        HStack(spacing: 10) {
                            Text("Format").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 60, alignment: .trailing)
                            TextField("{key} - {artist} - {title}", text: $settings.tagOptions.fileNameFormat).textFieldStyle(.roundedBorder).frame(width: 260)
                        }
                        .disabled(!o.renameFile)
                    }
                    .toggleStyle(.checkbox)
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Preview")
                        let key = sampleTrack?.key ?? MusicalKey.parse("8A")!
                        let energy = sampleTrack?.energy ?? 7
                        let bpm = sampleTrack?.bpm ?? 128
                        let title = sampleTrack?.displayTitle ?? "Song Title"
                        let artist = sampleTrack?.artist ?? "Artist"
                        let existingComment = sampleTrack?.existingTags.comment ?? ""
                        previewRow("Initial key", o.writeInitialKey ? key.formatted(o.notation) : "—")
                        previewRow("Comment", o.writeComment ? previewComment(o, key: key, energy: energy, bpm: bpm, title: title, artist: artist, existing: existingComment) : "—")
                        previewRow("Grouping", o.writeGrouping ? o.expand(o.groupingFormat, key: key, energy: energy, bpm: bpm, title: title, artist: artist) : "—")
                        previewRow("BPM", o.writeBPM ? TagWritingOptions.formatBPM(bpm, decimals: o.bpmDecimals) : "—")
                        previewRow("Title", o.prefixTitle ? o.expand(o.titleFormat, key: key, energy: energy, bpm: bpm, title: TagService.stripPreviousTag(title), artist: artist) : title)
                        previewRow("File name", o.renameFile ? TagService.sanitizeFileName(o.expand(o.fileNameFormat, key: key, energy: energy, bpm: bpm, title: title, artist: artist)) + "." + (sampleTrack?.url.pathExtension ?? "mp3") : (sampleTrack?.fileName ?? "song.mp3"))
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "When to write")
                        Toggle(isOn: $settings.tagOptions.autoWriteAfterAnalysis) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Write tags automatically after analysis").font(.system(size: 13, weight: .medium))
                                Text("Otherwise use Write Tags in the Analyze tab (⌘T).").font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        HStack {
                            let ids = library.tracks.filter { $0.result != nil }.map(\.id)
                            Button { FileActions.writeTags(ids: ids, analysis: analysis, state: state) } label: {
                                Label("Write tags to all \(ids.count) analyzed tracks now", systemImage: "tag")
                            }
                            .buttonStyle(ToolbarButtonStyle(prominent: true)).disabled(ids.isEmpty)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private func previewComment(_ o: TagWritingOptions, key: MusicalKey, energy: Int, bpm: Double, title: String, artist: String, existing: String) -> String {
        let tag = o.expand(o.commentFormat, key: key, energy: energy, bpm: bpm, title: title, artist: artist)
        let old = TagService.stripPreviousTag(existing)
        switch o.commentMode {
        case .overwrite: return tag
        case .prepend: return old.isEmpty ? tag : "\(tag) - \(old)"
        case .append: return old.isEmpty ? tag : "\(old) - \(tag)"
        }
    }

    @ViewBuilder
    private func previewRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .trailing)
            Text(value).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
        }
    }
}
