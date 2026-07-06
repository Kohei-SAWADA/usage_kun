import Foundation

public enum OnboardingDetector {
    public struct Detection: Equatable {
        public let claudeSignInFound: Bool
        public let codexSignInFound: Bool

        public init(claudeSignInFound: Bool, codexSignInFound: Bool) {
            self.claudeSignInFound = claudeSignInFound
            self.codexSignInFound = codexSignInFound
        }

        public var anyFound: Bool {
            claudeSignInFound || codexSignInFound
        }
    }

    public static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Detection {
        let fileManager = FileManager.default
        let claudeCredentials = home.appendingPathComponent(".claude/.credentials.json")
        let claudeConfig = home.appendingPathComponent(".claude.json")
        let codexAuth = home.appendingPathComponent(".codex/auth.json")

        return Detection(
            claudeSignInFound: fileManager.fileExists(atPath: claudeCredentials.path)
                || fileManager.fileExists(atPath: claudeConfig.path),
            codexSignInFound: fileManager.fileExists(atPath: codexAuth.path)
        )
    }
}
