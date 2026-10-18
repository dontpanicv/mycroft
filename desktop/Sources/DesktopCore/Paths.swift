import Foundation

public enum Paths {
    /// hands' state directory: `$HANDS_STATE_DIR`, else `~/Library/Application Support/hands` (as `hands` resolves it).
    public static func stateDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                      home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let dir = environment["HANDS_STATE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Application Support/hands", isDirectory: true)
    }

    /// The default socket: `desktop.sock` in hands' state directory.
    public static func defaultSocket(environment: [String: String] = ProcessInfo.processInfo.environment,
                                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        stateDirectory(environment: environment, home: home).appendingPathComponent("desktop.sock").path
    }
}
