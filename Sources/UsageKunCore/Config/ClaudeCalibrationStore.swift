import Foundation

public struct ClaudeCalibration: Codable, Equatable {
    public var capEstimate: Double
    public var sampleCount: Int
    public var planKey: String
    public var updatedAt: Date

    public init(capEstimate: Double, sampleCount: Int, planKey: String, updatedAt: Date) {
        self.capEstimate = capEstimate
        self.sampleCount = sampleCount
        self.planKey = planKey
        self.updatedAt = updatedAt
    }
}

public final class ClaudeCalibrationStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/usage_kun", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("claude_calibration.json")
        }

        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() -> ClaudeCalibration? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        return try? decoder.decode(ClaudeCalibration.self, from: data)
    }

    public func save(_ calibration: ClaudeCalibration) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(calibration)
        try data.write(to: fileURL, options: [.atomic])
    }
}
