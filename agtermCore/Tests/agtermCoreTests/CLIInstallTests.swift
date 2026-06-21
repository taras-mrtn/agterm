import Testing
@testable import agtermCore

struct CLIInstallTests {
    @Test func installPathIsToolUnderInstallDir() {
        #expect(CLIInstall.installPath == "/usr/local/bin/agtermctl")
    }

    @Test func shellQuoteWrapsPlainValue() {
        #expect(CLIInstall.shellQuote("/Applications/agterm.app") == "'/Applications/agterm.app'")
    }

    @Test func shellQuoteEscapesSingleQuotes() {
        #expect(CLIInstall.shellQuote("a'b") == "'a'\\''b'")
    }

    @Test func privilegedCommandLinksSourceToInstallPath() {
        let cmd = CLIInstall.privilegedInstallCommand(source: "/Apps/agterm.app/Contents/MacOS/agtermctl")
        #expect(cmd == "mkdir -p '/usr/local/bin' && ln -sf '/Apps/agterm.app/Contents/MacOS/agtermctl' '/usr/local/bin/agtermctl'")
    }

    @Test func privilegedCommandQuotesSourceWithSpaces() {
        let cmd = CLIInstall.privilegedInstallCommand(source: "/My Apps/agterm.app/Contents/MacOS/agtermctl")
        #expect(cmd.contains("ln -sf '/My Apps/agterm.app/Contents/MacOS/agtermctl' '/usr/local/bin/agtermctl'"))
    }
}
