import Foundation

@MainActor
final class DeviceStore {
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "ClashRemote", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appending(path: "devices.json")
    }

    func load() -> (devices: [RouterDevice], selected: UUID?) {
        guard let data = try? Data(contentsOf: url),
              let box = try? JSONDecoder().decode(Box.self, from: data)
        else {
            return ([], nil)
        }
        return (box.devices, box.selectedID)
    }

    func save(devices: [RouterDevice], selected: UUID?) {
        let box = Box(devices: devices, selectedID: selected)
        if let data = try? JSONEncoder().encode(box) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private struct Box: Codable {
        var devices: [RouterDevice]
        var selectedID: UUID?
    }
}
