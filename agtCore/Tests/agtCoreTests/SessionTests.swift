import Foundation
import Testing
@testable import agtCore

@MainActor
struct SessionTests {
    @Test(arguments: [
        ("/Users/umputun/dev/foo", "foo"),
        ("/", "/"),
        ("/a/b/", "b"),
        ("/Users/umputun", "umputun"),
        ("", "~"),
    ])
    func basenameDerivation(input: String, expected: String) {
        let session = Session(initialCwd: input)
        #expect(session.displayName == expected)
    }

    @Test func currentCwdOverridesInitialForDisplay() {
        let session = Session(initialCwd: "/start")
        #expect(session.displayName == "start")
        session.currentCwd = "/Users/umputun/dev/bar"
        #expect(session.displayName == "bar")
    }

    @Test func customNameOverridesAuto() {
        let session = Session(initialCwd: "/Users/umputun/dev/foo")
        #expect(session.displayName == "foo")
        session.customName = "build"
        #expect(session.displayName == "build")
    }

    @Test func clearingCustomNameRestoresAuto() {
        let session = Session(initialCwd: "/Users/umputun/dev/foo", customName: "build")
        #expect(session.displayName == "build")
        session.customName = nil
        #expect(session.displayName == "foo")
    }

    @Test func emptyCustomNameFallsBackToAuto() {
        let session = Session(initialCwd: "/Users/umputun/dev/foo", customName: "")
        #expect(session.displayName == "foo")
    }

    @Test func whitespaceOnlyCustomNameFallsBackToAuto() {
        // a whitespace-only customName can only reach displayName via a hand-edited
        // snapshot (renameSession clears blanks to nil); it's trimmed and falls back
        // to the basename, matching renameSession's behavior.
        let session = Session(initialCwd: "/Users/umputun/dev/foo", customName: "   \t")
        #expect(session.displayName == "foo")
    }

    @Test func paddedCustomNameDisplaysTrimmed() {
        // a padded customName (e.g. from a hand-edited snapshot) displays trimmed,
        // matching the "trimmed before use" contract.
        let session = Session(initialCwd: "/Users/umputun/dev/foo", customName: "  build  ")
        #expect(session.displayName == "build")
    }

    @Test func oscTitleOverridesCwd() {
        // no manual rename: the terminal title (e.g. a remote host over SSH) wins over the cwd basename.
        let session = Session(initialCwd: "/Users/umputun/dev/foo")
        #expect(session.displayName == "foo")
        session.oscTitle = "umputun@web1: ~/srv"
        #expect(session.displayName == "umputun@web1: ~/srv")
    }

    @Test func customNameOverridesOscTitle() {
        // a manual rename outranks the terminal title.
        let session = Session(initialCwd: "/Users/umputun/dev/foo", customName: "build")
        session.oscTitle = "umputun@web1: ~/srv"
        #expect(session.displayName == "build")
    }

    @Test func blankOscTitleFallsBackToCwd() {
        // a whitespace-only or empty title is trimmed and falls through to the cwd basename.
        let session = Session(initialCwd: "/Users/umputun/dev/foo")
        session.oscTitle = "   \t"
        #expect(session.displayName == "foo")
        session.oscTitle = ""
        #expect(session.displayName == "foo")
    }

    @Test func paddedOscTitleDisplaysTrimmed() {
        let session = Session(initialCwd: "/Users/umputun/dev/foo")
        session.oscTitle = "  web1  "
        #expect(session.displayName == "web1")
    }

    @Test func effectiveCwdFallsBackToInitialUntilPwdReport() {
        // a restored session has no currentCwd until OSC 7 arrives; effectiveCwd is
        // initialCwd so git status refreshes immediately on launch/select.
        let session = Session(initialCwd: "/repo")
        #expect(session.effectiveCwd == "/repo")
    }

    @Test func effectiveCwdPrefersCurrentCwdOnceReported() {
        let session = Session(initialCwd: "/repo")
        session.currentCwd = "/repo/sub"
        #expect(session.effectiveCwd == "/repo/sub")
    }
}
