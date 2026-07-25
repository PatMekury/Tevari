import AppIntents

/// These shortcuts open the private iPhone experience directly. The glasses
/// connection is deliberately not started by Siri; it remains an explicit,
/// on-screen choice for privacy-sensitive hardware access.
struct StartTevariPrayerIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a prayer"
    static var description = IntentDescription("Open Prayer in Tevari.")
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run { TevariAppRouter.shared.open(.prayer) }
        return .result(dialog: "Opening Prayer in Tevari.")
    }
}

struct OpenTevariFaithLensIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Faith Lens"
    static var description = IntentDescription("Open Faith Lens in Tevari.")
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run { TevariAppRouter.shared.open(.faithLens) }
        return .result(dialog: "Opening Faith Lens in Tevari.")
    }
}

struct StartTevariStoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a Bible story"
    static var description = IntentDescription("Open Story in Tevari.")
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run { TevariAppRouter.shared.open(.story) }
        return .result(dialog: "Opening Story in Tevari.")
    }
}

struct OpenTevariParallelIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Parallel"
    static var description = IntentDescription("Open Parallel in Tevari.")
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run { TevariAppRouter.shared.open(.parallel) }
        return .result(dialog: "Opening Parallel in Tevari.")
    }
}

struct TevariShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .orange
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartTevariPrayerIntent(), phrases: [
            "Start a prayer with \(.applicationName)",
            "Open prayer in \(.applicationName)"
        ], shortTitle: "Start prayer", systemImageName: "hands.sparkles")
        AppShortcut(intent: OpenTevariFaithLensIntent(), phrases: [
            "Open Faith Lens in \(.applicationName)",
            "Start Faith Lens with \(.applicationName)"
        ], shortTitle: "Faith Lens", systemImageName: "viewfinder.circle")
        AppShortcut(intent: StartTevariStoryIntent(), phrases: [
            "Start a Bible story with \(.applicationName)",
            "Open Story in \(.applicationName)"
        ], shortTitle: "Bible story", systemImageName: "book.closed")
        AppShortcut(intent: OpenTevariParallelIntent(), phrases: [
            "Open Parallel in \(.applicationName)",
            "Find a Parallel with \(.applicationName)"
        ], shortTitle: "Parallel", systemImageName: "arrow.triangle.branch")
    }
}
