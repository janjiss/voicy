import Foundation

final class MusicController {
    private let queue = DispatchQueue(label: "com.voicy.music")
    private var pausedApps: [String] = []

    func pause() {
        queue.async {
            let apps = ["Music", "Spotify"]
            self.pausedApps = apps.filter { self.isPlaying($0) }
            for app in self.pausedApps {
                self.runAppleScript("tell application \"\(app)\" to pause")
            }
        }
    }

    func resume() {
        queue.async {
            let apps = self.pausedApps
            self.pausedApps = []
            for app in apps {
                self.runAppleScript("tell application \"\(app)\" to play")
            }
        }
    }

    private func isPlaying(_ app: String) -> Bool {
        let script = """
        if application "\(app)" is running then
            tell application "\(app)" to if player state is playing then return "playing"
        end if
        return "stopped"
        """
        return runAppleScript(script).trimmingCharacters(in: .whitespacesAndNewlines) == "playing"
    }

    @discardableResult
    private func runAppleScript(_ script: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
