import ArgumentParser
import Darwin
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

// serialized: runSucceedsOnOkResponse and runThrowsExitCodeFailureOnErrorResponse both redirect the
// process-global STDOUT_FILENO via captureStdout, so running them in parallel races on stdout (one
// test's output lands in the other's pipe). serial execution keeps the redirect exclusive.
@Suite(.serialized)
struct SocketClientTests {
    @Test func roundTripOkResponse() throws {
        let canned = ControlResponse(ok: true, result: ControlResult(id: "9f3c"))
        let server = StubServer(response: canned)
        try server.start()
        defer { server.stop() }

        let client = SocketClient(path: server.path)
        let response = try client.send(ControlRequest(cmd: .sessionSelect, target: "active"))

        #expect(response.ok)
        #expect(response.result?.id == "9f3c")
        // the server echoed the request it received — confirm the client wrote it correctly.
        #expect(server.received?.cmd == .sessionSelect)
        #expect(server.received?.target == "active")
    }

    @Test func roundTripErrorResponse() throws {
        let canned = ControlResponse(ok: false, error: "cannot delete last workspace")
        let server = StubServer(response: canned)
        try server.start()
        defer { server.stop() }

        let client = SocketClient(path: server.path)
        let response = try client.send(ControlRequest(cmd: .workspaceDelete, target: "active"))

        #expect(!response.ok)
        #expect(response.error == "cannot delete last workspace")
    }

    @Test func connectFailureToMissingSocketThrows() {
        let client = SocketClient(path: NSTemporaryDirectory() + "agterm-missing-\(UUID().uuidString.prefix(8)).sock")
        #expect(throws: SocketClientError.self) { try client.send(ControlRequest(cmd: .tree)) }
    }

    /// `RequestCommand.run()` returns without throwing on a `{"ok":true}` response and prints the
    /// affected id to stdout.
    @Test func runSucceedsOnOkResponse() throws {
        let server = StubServer(response: ControlResponse(ok: true, result: ControlResult(id: "9f3c")))
        try server.start()
        defer { server.stop() }

        let command = try Tree.parse(["--socket", server.path])
        let printed = try captureStdout { try command.run() }
        #expect(printed == "9f3c\n")
    }

    /// Runs `body` with the process stdout redirected to a pipe, returning everything it printed.
    private func captureStdout(_ body: () throws -> Void) throws -> String {
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        defer { close(saved) }
        fflush(stdout)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        try body()
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// `RequestCommand.run()` throws `ExitCode.failure` on a `{"ok":false}` response.
    @Test func runThrowsExitCodeFailureOnErrorResponse() throws {
        let server = StubServer(response: ControlResponse(ok: false, error: "boom"))
        try server.start()
        defer { server.stop() }

        let command = try Tree.parse(["--socket", server.path, "--json"])
        #expect(throws: ExitCode.failure) { try command.run() }
    }

    @Test func formatResponseBareOk() {
        #expect(SocketClient.formatResponse(ControlResponse(ok: true), json: false) == "ok")
    }

    @Test func formatResponseId() {
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c"))
        #expect(SocketClient.formatResponse(response, json: false) == "9f3c")
    }

    @Test func formatResponseText() {
        let response = ControlResponse(ok: true, result: ControlResult(text: "selected\nlines"))
        #expect(SocketClient.formatResponse(response, json: false) == "selected\nlines")
    }

    @Test func formatResponseError() {
        #expect(SocketClient.formatResponse(ControlResponse(ok: false, error: "boom"), json: false) == "error: boom")
    }

    @Test func formatResponseErrorFallback() {
        // an error response with no message falls back to a generic line.
        #expect(SocketClient.formatResponse(ControlResponse(ok: false), json: false) == "error: unknown error")
    }

    @Test func formatResponseJSONIsRaw() throws {
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c"))
        let line = SocketClient.formatResponse(response, json: true)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: Data(line.utf8))
        #expect(decoded.ok)
        #expect(decoded.result?.id == "9f3c")
    }

    @Test func formatResponseTree() {
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: true)
        let workspace = ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])
        let tree = ControlTree(workspaces: [workspace])
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(tree: tree)), json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0] == "* work  [w1]")
        // active session (*), the (split) suffix, id and cwd columns.
        #expect(lines[1] == "  * shell (split)  [s1]  /tmp")
    }

    @Test func formatTreeMarksInactive() {
        let session = ControlSessionNode(id: "s2", name: "logs", cwd: "/var", active: false, split: false)
        let workspace = ControlWorkspaceNode(id: "w2", name: "other", active: false, sessions: [session])
        let tree = ControlTree(workspaces: [workspace])
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(tree: tree)), json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "  other  [w2]")
        #expect(lines[1] == "    logs  [s2]  /var")
    }

    @Test func formatResponseWindows() {
        let windows = [
            ControlWindowNode(id: "w1", name: "work", open: true, active: true),
            ControlWindowNode(id: "w2", name: "personal", open: true, active: false),
            ControlWindowNode(id: "w3", name: "archive", open: false, active: false),
            // a closed-but-active window (frontmost id pointing at a window not yet loaded) still
            // renders the [active] tag without [open].
            ControlWindowNode(id: "w4", name: "pending", open: false, active: true),
        ]
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(windows: windows)), json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0] == "w1  work [open] [active]")
        #expect(lines[1] == "w2  personal [open]")
        #expect(lines[2] == "w3  archive")
        #expect(lines[3] == "w4  pending [active]")
    }

    @Test func formatResponseEmptyWindows() {
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(windows: [])), json: false)
        // an empty window list renders an empty string (no per-window lines), not the bare ok line —
        // a present-but-empty `windows` payload still takes the windows branch.
        #expect(out == "")
    }
}

/// An in-process unix-socket server for the round-trip tests: binds a short temp path, accepts one
/// connection, reads the request line, records it, and writes back a canned `ControlResponse`.
private final class StubServer: @unchecked Sendable {
    let path: String
    private let canned: ControlResponse
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "stub.server")
    private(set) var received: ControlRequest?

    init(response: ControlResponse) {
        self.canned = response
        self.path = NSTemporaryDirectory() + "agterm-stub-\(UUID().uuidString.prefix(8)).sock"
    }

    func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketClientError("stub socket() failed") }
        unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { buf in
                pathBytes.withUnsafeBufferPointer { src in buf.update(from: src.baseAddress!, count: src.count) }
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw SocketClientError("stub bind failed: \(String(cString: strerror(errno)))")
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw SocketClientError("stub listen failed")
        }
        listenFD = fd
        queue.async { [self] in accept(fd) }
    }

    private func accept(_ fd: Int32) {
        let conn = Darwin.accept(fd, nil, nil)
        guard conn >= 0 else { return }
        defer { close(conn) }

        // read one request line.
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(conn, &byte, 1)
            if n <= 0 { break }
            if byte == UInt8(ascii: "\n") { break }
            buffer.append(byte)
        }
        received = try? JSONDecoder().decode(ControlRequest.self, from: buffer)

        // write the canned response.
        guard var data = try? JSONEncoder().encode(canned) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < data.count {
                let written = write(conn, base + offset, data.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }
}
