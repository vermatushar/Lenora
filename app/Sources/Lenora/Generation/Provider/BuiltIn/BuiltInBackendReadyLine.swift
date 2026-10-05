import Foundation

enum BuiltInBackendReadyLine {
    static func port(from line: String) -> Int? {
        guard let match = line.wholeMatch(of: /LENORA_READY port=([0-9]{1,5})/),
              let port = Int(match.1), (1...65535).contains(port) else { return nil }
        return port
    }
}
