import agtCore
import Foundation

/// The observable settings state for the Settings window. Loads `AppSettings` from `SettingsStore`
/// at init; each mutation persists AND applies live to the running terminals.
///
/// Applying writes the ghostty settings file, rebuilds + broadcasts the config to every live
/// surface, and clears per-session font-size overrides (the shared `update_config` resets all
/// surfaces to the new default, so the persisted overrides are cleared to match).
@Observable
@MainActor
final class SettingsModel {
    /// The window library; a config reload broadcasts to the surfaces of EVERY open window (and
    /// every window's quick terminal), so a settings change updates all windows live.
    private let library: WindowLibrary
    private let settingsStore: SettingsStore
    private(set) var settings: AppSettings

    init(library: WindowLibrary, settingsStore: SettingsStore) {
        self.library = library
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
        // mirror the persisted window translucency + notification toggle + compact toolbar into
        // their shared channels at launch, before any settings change fires.
        applyWindowTranslucency()
        applyNotificationsEnabled()
        applyCompactToolbar()
    }

    func setFontFamily(_ value: String?) { settings.fontFamily = value; persistAndApply() }
    func setFontSize(_ value: Double?) { settings.fontSize = value; persistAndApply() }
    func setTheme(_ value: String?) { settings.theme = value; persistAndApply() }
    func setBackgroundOpacity(_ value: Double?) { settings.backgroundOpacity = value; persistAndApply() }
    func setBackgroundBlur(_ value: Int?) { settings.backgroundBlur = value; persistAndApply() }
    func setNotificationsEnabled(_ value: Bool?) { settings.notificationsEnabled = value; persistAndApply() }
    func setCompactToolbar(_ value: Bool?) { settings.compactToolbar = value; persistAndApply() }

    private func persistAndApply() {
        try? settingsStore.save(settings)
        // only rebuild + rebroadcast the ghostty config (which resets every surface to the default
        // font size) when the generated config TEXT actually changed. A window-opacity drag within
        // the translucent range, or a blur change, leaves the config identical — re-syncing the
        // window alone is enough and avoids hammering surface rebuilds on every slider tick.
        if writeGhosttyConfig() {
            GhosttyApp.shared.reloadConfig(surfaces: liveSurfaces())
            // clear per-session font overrides in EVERY window — open ones live, closed ones by
            // rewriting their snapshot file (the shared config reset every surface to the default
            // size, so a closed window mustn't reopen later overriding the new default).
            library.resetSessionFontSizesAllWindows()
        }
        applyWindowTranslucency()
        applyNotificationsEnabled()
        applyCompactToolbar()
        // refresh the app chrome (title bar + sidebar + quick terminal) with the new terminal color,
        // window translucency, and toolbar style immediately, rather than only when the window next
        // re-keys. The title-bar re-sync and the cwd-subtitle drop both ride this notification.
        NotificationCenter.default.post(name: .agtAppearanceChanged, object: nil)
    }

    private func applyWindowTranslucency() {
        GhosttyApp.shared.setWindowTranslucency(opacity: settings.backgroundOpacity ?? 1,
                                                blurRadius: settings.backgroundBlur ?? 0)
    }

    private func applyNotificationsEnabled() {
        NotificationManager.shared.bannersEnabled = settings.notificationsEnabled ?? true
    }

    private func applyCompactToolbar() {
        GhosttyApp.shared.setCompactToolbar(settings.compactToolbar ?? false)
    }

    /// Write the ghostty config lines (font/size/theme + the translucency pins) to the file
    /// `GhosttyApp.loadConfig` reads. Returns true if the file content changed, so the caller can
    /// skip the expensive reload when it didn't.
    private func writeGhosttyConfig() -> Bool {
        let url = GhosttyApp.settingsConfigURL
        let text = settings.ghosttyConfigLines().joined(separator: "\n") + "\n"
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// All live ghostty surfaces across every open window: each session's primary + split surface in
    /// every open window's store, plus every open window's quick terminal. A config reload therefore
    /// broadcasts to all windows, not just the frontmost one.
    private func liveSurfaces() -> [GhosttySurfaceView] {
        var views = library.openIDs()
            .compactMap { library.store(for: $0) }
            .flatMap(\.workspaces)
            .flatMap(\.sessions)
            .flatMap { [$0.surface, $0.splitSurface] }
            .compactMap { $0 as? GhosttySurfaceView }
        views += QuickTerminalRegistry.shared.allControllers().compactMap { $0.currentSurface() }
        return views
    }
}
