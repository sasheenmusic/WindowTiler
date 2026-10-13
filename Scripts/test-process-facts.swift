// Run from the project root:
// swiftc Sources/WindowTilerApp/ProcessFacts.swift Scripts/test-process-facts.swift -o /tmp/windowtiler-process-facts-tests
// /tmp/windowtiler-process-facts-tests
// Reads real process facts from short-lived command-line children (perl
// sleeping, nothing with a window) and from this process. It never opens a
// window, so a running Window Tiler has nothing to react to.
import Darwin
import Foundation

@main
enum ProcessFactsTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Perl rather than a shell: a shell may replace itself with its last
    /// command and lose the arguments, or leave a grandchild behind.
    static func sleepingPerl(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "sleep 30", "--"] + arguments
        return process
    }

    static func wait(for what: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            try require(Date() < deadline, "Timed out waiting for \(what).")
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    static func buffer(count: Int32, path: String, padding: Int, arguments: [String], environment: [String]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: count) { Array($0) }
        bytes += Array(path.utf8) + [0] + [UInt8](repeating: 0, count: padding)
        for text in arguments + environment { bytes += Array(text.utf8) + [0] }
        return bytes
    }

    static func run() throws {
        try checkParser()
        try checkThisProcess()
        let reader = ProcessFactsReader()
        let own = reader.facts(for: getpid())
        try checkChild(reader, own: own)
        try checkOrphan(reader, own: own)
        try checkCache()
        try checkLiveness()
        print("PASS: all process fact checks")
    }

    static func checkParser() throws {
        let environment = ["PATH=/usr/bin", "HOME=/tmp"]
        let standard = buffer(count: 3, path: "/bin/sh", padding: 5, arguments: ["sh", "-c", "true"], environment: environment)
        try require(ProcessFactsReader.parseArguments(standard) == ["sh", "-c", "true"],
                    "Arguments were not separated from the path, padding, and environment.")
        let empty = buffer(count: 4, path: "/bin/sh", padding: 1, arguments: ["sh", "", "x", ""], environment: environment)
        try require(ProcessFactsReader.parseArguments(empty) == ["sh", "", "x", ""], "Empty arguments were lost.")
        let overstated = buffer(count: 9, path: "/bin/sh", padding: 0, arguments: ["sh"], environment: [])
        try require(ProcessFactsReader.parseArguments(overstated) == ["sh"], "An argument count past the data was trusted.")
        try require(ProcessFactsReader.parseArguments([1, 0, 0]) == nil, "A buffer shorter than its header was accepted.")
        try require(ProcessFactsReader.parseArguments([]) == nil, "An empty buffer was accepted.")
        let unterminated = buffer(count: 1, path: "/bin/sh", padding: 0, arguments: [], environment: []) + Array("sh".utf8)
        try require(ProcessFactsReader.parseArguments(unterminated) == ["sh"], "A final argument without a terminator was lost.")
        print("PASS: argument buffers parse exactly and tolerate malformed data")
    }

    static func checkThisProcess() throws {
        let reader = ProcessFactsReader()
        guard let facts = reader.facts(for: getpid()) else { throw Failure(description: "This process has no facts.") }
        try require(facts.arguments == CommandLine.arguments, "This process's own arguments were misread: \(facts.arguments)")
        try require(facts.parentPID == getppid(), "This process's parent was misread: \(facts.parentPID).")
        try require(reader.facts(for: 0) == nil && reader.facts(for: -1) == nil, "A non-process id produced facts.")
        try require(reader.facts(for: 2_000_000) == nil, "A process id that cannot exist produced facts.")
        print("PASS: own process facts match what the system reports")
    }

    static func checkChild(_ reader: ProcessFactsReader, own: ProcessFactsReader.Facts?) throws {
        let flags = ["--remote-debug", "tcp://127.0.0.1:6007"]
        let child = sleepingPerl(arguments: flags)
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        guard let facts = reader.facts(for: child.processIdentifier) else { throw Failure(description: "The child has no facts.") }
        try require(facts.parentPID == getpid(), "The child's parent is \(facts.parentPID), not this process.")
        try require(facts.arguments == ["/usr/bin/perl", "-e", "sleep 30", "--"] + flags, "The child's arguments were misread: \(facts.arguments)")
        guard let responsible = facts.responsiblePID else {
            throw Failure(description: "The responsible process is unavailable; the private lookup may have changed.")
        }
        try require(responsible != child.processIdentifier, "The child was reported responsible for itself.")
        try require(responsible == own?.responsiblePID, "The child's responsible process differs from its parent's.")
        try require(facts.responsibleIsAlive, "A running responsible process was reported gone.")
        try require(reader.facts(for: child.processIdentifier) == facts, "A second read of the child changed its facts.")
        print("PASS: a command-line child reports its parent, exact arguments, and live responsible process (\(responsible))")
    }

    /// The case the responsible process exists for: a background run whose
    /// parent has exited belongs to launchd, yet is still tied to the app it
    /// came from.
    static func checkOrphan(_ reader: ProcessFactsReader, own: ProcessFactsReader.Facts?) throws {
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        launcher.arguments = ["-e", """
            my $pid = fork();
            die "fork failed" unless defined $pid;
            if ($pid) { print "$pid\\n"; exit 0 }
            close(STDOUT);
            exec "/usr/bin/perl", "-e", "sleep 30", "--", "--editor-pid", "1";
            """]
        let output = Pipe()
        launcher.standardOutput = output
        try launcher.run()
        launcher.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let orphan = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure(description: "The launcher did not report a child: \(text)")
        }
        defer { kill(orphan, SIGKILL) }
        try wait(for: "the orphan to reach launchd") { reader.facts(for: orphan)?.parentPID == 1 }
        guard let facts = reader.facts(for: orphan) else { throw Failure(description: "The orphan has no facts.") }
        try require(facts.arguments.suffix(2) == ["--editor-pid", "1"], "The orphan's arguments were misread: \(facts.arguments)")
        try require(facts.responsiblePID != nil && facts.responsiblePID == own?.responsiblePID,
                    "The orphan lost its responsible process: \(String(describing: facts.responsiblePID)).")
        try require(facts.responsibleIsAlive, "The orphan's running responsible process was reported gone.")
        print("PASS: an orphaned process keeps its responsible process after its parent exits")
    }

    static func checkCache() throws {
        var parent: pid_t = 10
        var responsible: pid_t? = 20
        var started = ProcessFactsReader.StartTime(seconds: 100, microseconds: 5)
        var argumentReads = 0
        var argumentsReadable = true
        let reader = ProcessFactsReader(
            kernelInfo: { _ in (parent, started) },
            readArguments: { _ in argumentReads += 1; return argumentsReadable ? ["run\(argumentReads)"] : nil },
            readResponsiblePID: { _ in responsible }
        )
        try require(reader.facts(for: 4242)?.arguments == ["run1"], "The first read missed the arguments.")
        try require(reader.facts(for: 4242)?.arguments == ["run1"] && argumentReads == 1, "A repeat read asked the system for arguments again.")
        parent = 1
        responsible = 4242
        let relaunched = reader.facts(for: 4242)
        try require(relaunched?.parentPID == 1 && relaunched?.responsiblePID == 4242 && relaunched?.arguments == ["run1"] && argumentReads == 1,
                    "A changed parent or responsible process was served from the cache.")
        responsible = nil
        try require(reader.facts(for: 4242)?.responsiblePID == nil, "An unreadable responsible process kept its old value.")
        started = ProcessFactsReader.StartTime(seconds: 100, microseconds: 6)
        try require(reader.facts(for: 4242)?.arguments == ["run2"] && argumentReads == 2,
                    "A reused process id kept the old process's arguments.")
        started = ProcessFactsReader.StartTime(seconds: 100, microseconds: 7)
        argumentsReadable = false
        try require(reader.facts(for: 4242)?.arguments == [] && reader.cachedProcessCount == 0,
                    "Unreadable arguments were reported from, or cached for, an earlier process.")
        argumentsReadable = true
        try require(reader.facts(for: 4242)?.arguments == ["run4"], "A failed argument read was not retried.")
        print("PASS: only arguments are cached, keyed by start time; parent and responsible process are read every time")
    }

    static func checkLiveness() throws {
        try require(ProcessFactsReader.isAlive(getpid()), "This process was reported gone.")
        try require(ProcessFactsReader.isAlive(1), "launchd (not ours to signal) was reported gone.")
        try require(!ProcessFactsReader.isAlive(0) && !ProcessFactsReader.isAlive(-1), "A non-process id was reported alive.")

        let reader = ProcessFactsReader()
        let child = sleepingPerl(arguments: ["--remote-debug", "x"])
        try child.run()
        let pid = child.processIdentifier
        try require(reader.facts(for: pid) != nil && reader.cachedProcessCount == 1, "The child was not cached.")
        try require(ProcessFactsReader.isAlive(pid), "A running child was reported gone.")
        kill(pid, SIGKILL)
        child.waitUntilExit()
        try require(!ProcessFactsReader.isAlive(pid), "A killed child was reported alive.")
        try require(reader.facts(for: pid) == nil && reader.cachedProcessCount == 0, "A killed child kept its facts.")

        let other = sleepingPerl(arguments: ["--remote-debug", "y"])
        try other.run()
        defer { other.terminate(); other.waitUntilExit() }
        try require(reader.facts(for: other.processIdentifier) != nil, "The second child has no facts.")
        reader.forget(except: [])
        try require(reader.cachedProcessCount == 0, "Quit processes stayed cached.")
        print("PASS: a killed process yields no facts, and quit processes leave the cache")
    }
}
