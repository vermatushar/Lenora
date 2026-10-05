import Foundation

enum BuiltInBackendEnvironment {
    static func make(keys: ProviderKeys, token: String, dataDirectory: URL, parentPID: Int32,
                     base: [String: String]) -> [String: String] {
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "LENORA_ENV": "production",
            "LENORA_HOST": "127.0.0.1",
            "LENORA_PORT": "0",
            "LENORA_DATA_DIR": dataDirectory.path(percentEncoded: false),
            "LENORA_TOKEN": token,
            "LENORA_PARENT_PID": String(parentPID),
        ]
        for name in ["HOME", "TMPDIR", "LANG"] {
            if let value = base[name] { environment[name] = value }
        }
        let provided: [(String, String?)] = [
            ("LENORA_CLOUDINARY_CLOUD_NAME", keys.cloudinaryCloudName),
            ("LENORA_CLOUDINARY_API_KEY", keys.cloudinaryAPIKey),
            ("LENORA_CLOUDINARY_API_SECRET", keys.cloudinaryAPISecret),
            ("LENORA_OPENAI_API_KEY", keys.openAIAPIKey),
        ]
        for (name, value) in provided {
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                environment[name] = value
            }
        }
        return environment
    }
}
