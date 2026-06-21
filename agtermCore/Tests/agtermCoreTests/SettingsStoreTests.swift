import Foundation
import Testing
@testable import agtermCore

/// Class suite so `init`/`deinit` create and tear down a unique temp directory per test — no
/// shared on-disk state, no Application Support pollution.
@MainActor
final class SettingsStoreTests {
    private let directory: URL
    private let store: SettingsStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-settings-\(UUID().uuidString)")
        store = SettingsStore(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("settings.json") }

    @Test func saveLoadRoundTrip() throws {
        let settings = AppSettings(fontFamily: "Menlo", fontSize: 15, theme: "Adwaita Dark")
        try store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func missingFileReturnsDefault() {
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(store.load() == AppSettings())
    }

    @Test func corruptFileReturnsDefault() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not valid json ]".utf8).write(to: fileURL)
        #expect(store.load() == AppSettings())
    }

    @Test func saveCreatesDirectoryWhenMissing() throws {
        let nested = directory.appendingPathComponent("does/not/exist/yet")
        let nestedStore = SettingsStore(directory: nested)
        let settings = AppSettings(theme: "Alabaster")
        try nestedStore.save(settings)
        #expect(nestedStore.load() == settings)
    }
}
