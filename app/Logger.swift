import Foundation

let VTTLogger = {
    let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs")
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    let logURL = logDir.appendingPathComponent("VoiceToText.log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let handle = try? FileHandle(forWritingTo: logURL)
    return VTTLog(handle: handle)
}()

struct VTTLog {
    let handle: FileHandle?

    func log(_ message: String, _ extras: [String: Any] = [:]) {
        let iso = ISO8601DateFormatter()
        let parts = extras.isEmpty ? "" : " " + extras.map { "\($0)=\($1)" }.joined(separator: " ")
        let line = "[\(iso.string(from: Date()))] \(message)\(parts)\n"
        print(line.trimmingCharacters(in: .newlines))
        handle?.seekToEndOfFile()
        handle?.write(Data(line.utf8))
    }
}
