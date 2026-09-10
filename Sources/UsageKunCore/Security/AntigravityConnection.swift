import Foundation
import Darwin

/// Ephemeral local CSRF credentials. Never persisted or logged.
struct AntigravityConnection: Sendable {
    let port: Int
    let csrfToken: String

    static func discover() -> [AntigravityConnection] {
        // Identify actual executables first, rather than matching arbitrary command
        // arguments (which can contain source text from a shell or an editor).
        let processes = run("/bin/ps", ["-ww", "-U", String(getuid()), "-o", "pid=,comm="])
        var connections: [AntigravityConnection] = []
        for line in processes.split(separator: "\n") {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, Int(fields[0]) != nil else { continue }
            let pid = String(fields[0])
            let executable = String(fields[1]).trimmingCharacters(in: .whitespaces)
            guard executable.contains(".app/Contents/Resources/app/extensions/antigravity/bin/"),
                  ["language_server_macos_arm", "language_server_macos_x64"].contains(URL(fileURLWithPath: executable).lastPathComponent),
                  FileManager.default.isExecutableFile(atPath: executable) else { continue }
            let arguments = run("/bin/ps", ["-ww", "-p", pid, "-o", "args="])
            guard let token = capture("--csrf_token(?:=|\\s+)([A-Za-z0-9_-]+)(?:\\s|$)", in: arguments) else { continue }
            let sockets = run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"])
            var ports = Set<Int>()
            for socket in sockets.split(separator: "\n") where socket.hasPrefix("n127.0.0.1:") || socket.hasPrefix("n[::1]:") || socket.hasPrefix("n*:") {
                if let text = socket.split(separator: ":").last, let port = Int(text), (1...65535).contains(port) {
                    ports.insert(port)
                }
            }
            connections += ports.sorted().prefix(4).map { AntigravityConnection(port: $0, csrfToken: token) }
            if connections.count >= 12 { break }
        }
        return connections
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
