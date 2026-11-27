import Foundation

/// Saves bookmarks, history and open tabs as files that iOS keeps encrypted
/// whenever the device is locked.
enum Storage {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("PianoBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let file = folder.appendingPathComponent("\(key).json")
        if let data = try? Data(contentsOf: file) {
            return try? JSONDecoder().decode(type, from: data)
        }
        // Earlier versions kept this in the (less protected) preferences file.
        guard let old = UserDefaults.standard.data(forKey: key) else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        try? old.write(to: file, options: [.atomic, .completeFileProtection])
        return try? JSONDecoder().decode(type, from: old)
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: folder.appendingPathComponent("\(key).json"), options: [.atomic, .completeFileProtection])
    }
}
