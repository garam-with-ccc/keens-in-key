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
        .sheet(item: $state.newNodeRequest) { req in NewNodeSheet(request: req) }
        .sheet(isPresented: Binding(get: { state.editingNode != nil }, set: { if !$0 { state.editingNode = nil } })) {
            if let id = state.editingNode { EditNodeSheet(nodeId: id) }
        }
        .sheet(isPresented: Binding(get: { state.editingSmartRules != nil }, set: { if !$0 { state.editingSmartRules = nil } })) {
            if let id = state.editingSmartRules { SmartRulesSheet(nodeId: id) }
        }
        .sheet(isPresented: $state.showTagManager) { TagManagerSheet() }
    }
}
