import SwiftUI
import KeensInKeyCore

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(AnalysisController.self) private var analysis

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 0) {
            SidebarView()
            Rectangle().fill(Theme.border).frame(width: 1)
            Group {
                switch state.page {
                case .analyze: AnalyzeView()
                case .cues: CuePointsView()
                case .wheel: CamelotWheelPage()
                case .personalize: PersonalizeView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .alert(state.alertTitle, isPresented: Binding(get: { state.alertMessage != nil }, set: { if !$0 { state.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.alertMessage ?? "")
        }
        .dropDestination(for: URL.self) { urls, _ in
            let ids = library.add(urls: urls)
            if settings.autoAnalyzeOnAdd { analysis.enqueue(ids) }
            if !ids.isEmpty { state.page = .analyze }
            return !ids.isEmpty
        }
    }
}

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
            .padding(.bottom, 22)

            ForEach(Page.allCases) { page in
                Button {
                    state.page = page
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: page.icon)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 20)
                        Text(page.title).font(.system(size: 13, weight: state.page == page ? .semibold : .regular))
                        Spacer()
                    }
                    .foregroundStyle(state.page == page ? Theme.accent : Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(state.page == page ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
            }

            Spacer()

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
        .frame(width: 200)
        .background(Theme.sidebar)
    }
}
