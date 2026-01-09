import SwiftUI

enum SkillPlatform: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case codex = "Codex"
    case claude = "Claude Code"
    case opencode = "OpenCode"
    case copilot = "GitHub Copilot"

    var id: String { rawValue }

    var storageKey: String {
        switch self {
        case .codex:
            return "codex"
        case .claude:
            return "claude"
        case .opencode:
            return "opencode"
        case .copilot:
            return "copilot"
        }
    }

    /// Relative path from a base directory to the skills folder
    var relativePath: String {
        switch self {
        case .codex:
            return ".codex/skills/public"
        case .claude:
            return ".claude/skills"
        case .opencode:
            return ".config/opencode/skill"
        case .copilot:
            return ".copilot/skills"
        }
    }

    var rootURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(relativePath)
    }

    /// Returns the skills URL for this platform within a given base directory
    func skillsURL(in baseURL: URL) -> URL {
        baseURL.appendingPathComponent(relativePath)
    }

    var description: String {
        "Install in \(rootURL.path)"
    }

    var badgeTint: Color {
        switch self {
        case .codex:
            return Color(red: 164.0 / 255.0, green: 97.0 / 255.0, blue: 212.0 / 255.0)
        case .claude:
            return Color(red: 217.0 / 255.0, green: 119.0 / 255.0, blue: 87.0 / 255.0)
        case .opencode:
            return Color(red: 76.0 / 255.0, green: 144.0 / 255.0, blue: 226.0 / 255.0)
        case .copilot:
            return Color(red: 77.0 / 255.0, green: 212.0 / 255.0, blue: 212.0 / 255.0)
        }
    }
}
