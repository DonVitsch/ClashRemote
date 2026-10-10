import Foundation

@MainActor
final class ProfileStore {
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "ClashRemote", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appending(path: "profile.json")
    }

    func load() -> LocalProfile {
        guard let data = try? Data(contentsOf: url),
              let profile = try? JSONDecoder().decode(LocalProfile.self, from: data)
        else {
            return .default
        }
        return profile
    }

    func save(_ profile: LocalProfile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        try data.write(to: url, options: .atomic)
    }
}
