import SwiftUI
import AppKit
import KeensInKeyCore

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(AnalysisController.self) private var analysis
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var settings = settings
        SnapshotScroll {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings").font(.system(size: 20, weight: .bold))

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Analysis")
                        row("Key profile") {
                            Picker("", selection: $settings.analysis.keyProfile) {
                                ForEach(KeyProfile.allCases) { p in Text(p.displayName).tag(p) }
                            }.labelsHidden().frame(width: 260)
                        }
                        row("Key matching") {
                            Picker("", selection: $settings.analysis.keySimilarity) {
                                ForEach(KeyDetector.Similarity.allCases) { s in Text(s.displayName).tag(s) }
                            }.labelsHidden().frame(width: 260)
                        }
                        row("BPM range") {
                            HStack(spacing: 8) {
                                Stepper(value: $settings.analysis.minBPM, in: 40...150, step: 5) { Text("\(Int(settings.analysis.minBPM))").monospacedDigit().frame(width: 34) }
                                Text("to").foregroundStyle(Theme.textSecondary)
                                Stepper(value: $settings.analysis.maxBPM, in: 100...300, step: 5) { Text("\(Int(settings.analysis.maxBPM))").monospacedDigit().frame(width: 34) }
                                Text("Tempi outside this range are halved or doubled (e.g. drum & bass 87 → 174).").font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        row("Cue points") {
                            HStack(spacing: 8) {
                                Stepper(value: $settings.analysis.cueCount, in: 1...8) { Text("up to \(settings.analysis.cueCount)").frame(width: 60, alignment: .leading) }
                                Picker("Quantize to", selection: $settings.quantize) {
                                    ForEach(QuantizeMode.allCases) { m in Text(m.displayName).tag(m) }
                                }.frame(width: 220)
                            }
                        }
                        row("Parallel jobs") {
                            Stepper(value: $settings.concurrency, in: 1...16) { Text("\(settings.concurrency)").monospacedDigit().frame(width: 30) }
                        }
                        row("") {
                            Toggle("Analyze files automatically when added", isOn: $settings.autoAnalyzeOnAdd).toggleStyle(.checkbox)
                        }
                        Text("Changes apply to the next analysis. Use Analysis ▸ Analyze Selected to re-analyze existing tracks.").font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Display")
                        row("Key notation") {
                            Picker("", selection: $settings.displayNotation) {
                                ForEach(KeyNotation.allCases) { n in Text(n.displayName).tag(n) }
                            }.labelsHidden().frame(width: 260)
                        }
                        row("BPM decimals") {
                            Picker("", selection: $settings.bpmDisplayDecimals) { Text("128").tag(0); Text("128.0").tag(1); Text("128.00").tag(2) }
                                .labelsHidden().pickerStyle(.segmented).frame(width: 200)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Library")
                        row("Location") {
                            HStack {
                                Text(LibraryStore.fileURL.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([LibraryStore.fileURL]) }.buttonStyle(ToolbarButtonStyle())
                            }
                        }
                        row("Tracks") {
                            Text("\(library.tracks.count) total · \(library.tracks.filter { $0.result != nil }.count) analyzed · \(library.tracks.filter(\.isMissing).count) missing")
                        }
                        HStack(spacing: 8) {
                            Button { library.removeMissing() } label: { Label("Remove Missing Files", systemImage: "doc.badge.ellipsis") }.buttonStyle(ToolbarButtonStyle())
                            Button { analysis.enqueue(library.tracks.map(\.id), force: true) } label: { Label("Re-analyze Everything", systemImage: "arrow.clockwise") }.buttonStyle(ToolbarButtonStyle())
                            Button(role: .destructive) {
                                library.removeAll()
                                state.selection.removeAll()
                            } label: { Label("Clear Library", systemImage: "trash") }.buttonStyle(ToolbarButtonStyle(destructive: true))
                        }
                        Text("Clearing the library never touches your audio files.").font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "About")
                        Text("Keens In Key \(AppInfo.version)").font(.system(size: 13, weight: .semibold))
                        Text("Open-source key, BPM, energy and cue point analysis for DJs, inspired by Mixed In Key. Key detection uses a 5-octave constant-Q chromagram with harmonic reassignment matched against tone profiles; tempo uses an onset-envelope autocorrelation with dynamic-programming beat tracking.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        HStack {
                            Button("GitHub") { if let u = URL(string: "https://github.com/garam-with-ccc/keens-in-key") { NSWorkspace.shared.open(u) } }.buttonStyle(ToolbarButtonStyle())
                            Button("Reset Settings") { settings.reset() }.buttonStyle(ToolbarButtonStyle())
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .trailing)
            content()
            Spacer()
        }
    }
}
