import CryptoKit
import Foundation
import Observation

@MainActor
@Observable final class SkillStore {
    enum ListState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum DetailState: Equatable {
        case idle
        case loading
        case loaded
        case missing
        case failed(String)
    }

    struct LocalSkillGroup: Identifiable {
        let id: Skill.ID
        let skill: Skill
        let installedPlatforms: Set<SkillPlatform>
        let deleteIDs: [Skill.ID]
    }

    struct PublishState: Codable {
        let lastPublishedHash: String
        let lastPublishedAt: Date
    }

    struct CliStatus {
        let isInstalled: Bool
        let isLoggedIn: Bool
        let username: String?
        let errorMessage: String?
    }

    var skills: [Skill] = []
    var listState: ListState = .idle
    var detailState: DetailState = .idle
    var referenceState: DetailState = .idle
    var selectedSkillID: Skill.ID?
    var selectedMarkdown: String = ""
    var selectedReferenceID: SkillReference.ID?
    var selectedReferenceMarkdown: String = ""

    var selectedSkill: Skill? {
        skills.first { $0.id == selectedSkillID }
    }

    var selectedReference: SkillReference? {
        guard let selectedSkill, let selectedReferenceID else { return nil }
        return selectedSkill.references.first { $0.id == selectedReferenceID }
    }

    func loadSkills() async {
        listState = .loading
        detailState = .idle
        referenceState = .idle
        do {
            let skills = try SkillPlatform.allCases.flatMap { platform in
                try loadSkills(from: platform.rootURL, platform: platform)
            }

            self.skills = skills.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

            listState = .loaded
            if let selectedSkillID,
               self.skills.contains(where: { $0.id == selectedSkillID }) == false {
                self.selectedSkillID = self.skills.first?.id
            } else if selectedSkillID == nil {
                selectedSkillID = self.skills.first?.id
            }

            normalizeSelectionToPreferredPlatform()
            await loadSelectedSkill()
        } catch {
            listState = .failed(error.localizedDescription)
        }
    }

    func loadSelectedSkill() async {
        guard let selectedSkill else {
            detailState = .idle
            selectedMarkdown = ""
            referenceState = .idle
            selectedReferenceID = nil
            selectedReferenceMarkdown = ""
            return
        }

        let skillURL = selectedSkill.skillMarkdownURL

        detailState = .loading
        referenceState = .idle
        selectedReferenceID = nil
        selectedReferenceMarkdown = ""

        do {
            let raw = try String(contentsOf: skillURL, encoding: .utf8)
            selectedMarkdown = stripFrontmatter(from: raw)
            detailState = .loaded
        } catch {
            detailState = .failed(error.localizedDescription)
            selectedMarkdown = ""
        }
    }

    func selectReference(_ reference: SkillReference) async {
        selectedReferenceID = reference.id
        await loadSelectedReference()
    }

    func loadSelectedReference() async {
        guard let selectedReference else {
            referenceState = .idle
            selectedReferenceMarkdown = ""
            return
        }

        referenceState = .loading

        do {
            let raw = try String(contentsOf: selectedReference.url, encoding: .utf8)
            selectedReferenceMarkdown = stripFrontmatter(from: raw)
            referenceState = .loaded
        } catch {
            referenceState = .failed(error.localizedDescription)
            selectedReferenceMarkdown = ""
        }
    }

    func deleteSkills(ids: [Skill.ID]) async {
        let fileManager = FileManager.default
        for id in ids {
            guard let skill = skills.first(where: { $0.id == id }) else { continue }
            try? fileManager.removeItem(at: skill.folderURL)
        }
        await loadSkills()
    }

    func isOwnedSkill(_ skill: Skill) -> Bool {
        let originURL = skill.folderURL
            .appendingPathComponent(".clawdhub")
            .appendingPathComponent("origin.json")
        return !FileManager.default.fileExists(atPath: originURL.path)
    }

    func isInstalled(slug: String) -> Bool {
        skills.contains { $0.name == slug }
    }

    func isInstalled(slug: String, in platform: SkillPlatform) -> Bool {
        skills.contains { $0.name == slug && $0.platform == platform }
    }

    func installedPlatforms(for slug: String) -> Set<SkillPlatform> {
        Set(skills.filter { $0.name == slug }.map(\.platform))
    }

    func groupedLocalSkills(from filteredSkills: [Skill]) -> [LocalSkillGroup] {
        let grouped = Dictionary(grouping: filteredSkills, by: { $0.name })
        let preferredPlatformOrder: [SkillPlatform] = [.codex, .claude]

        return grouped.compactMap { slug, filteredSkills in
            let allSkillsForSlug = skills.filter { $0.name == slug }

            guard let preferredSelection = preferredPlatformOrder
                .compactMap({ platform in allSkillsForSlug.first(where: { $0.platform == platform }) })
                .first ?? allSkillsForSlug.first else {
                return nil
            }

            let preferredContent = preferredPlatformOrder
                .compactMap({ platform in filteredSkills.first(where: { $0.platform == platform }) })
                .first ?? filteredSkills.first ?? preferredSelection

            return LocalSkillGroup(
                id: preferredSelection.id,
                skill: preferredContent,
                installedPlatforms: Set(allSkillsForSlug.map(\.platform)),
                deleteIDs: allSkillsForSlug.map(\.id)
            )
        }
        .sorted { lhs, rhs in
            lhs.skill.displayName.localizedCaseInsensitiveCompare(rhs.skill.displayName) == .orderedAscending
        }
    }

    func skillNeedsPublish(_ skill: Skill) async -> Bool {
        do {
            let hash = try await Task.detached { try Self.computeSkillHash(for: skill) }.value
            let state = loadPublishState(for: skill.name)
            return state?.lastPublishedHash != hash
        } catch {
            return true
        }
    }

    func publishSkill(
        _ skill: Skill,
        bump: PublishBump,
        changelog: String,
        tags: [String],
        publishedVersion: String?
    ) async throws {
        try await Task.detached {
            guard let bunx = Self.resolveBunxPath() else {
                throw NSError(domain: "ClawdhubPublish", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Bun is not installed."
                ])
            }
            let version = Self.publishVersion(for: publishedVersion, bump: bump)
            let args = Self.publishArguments(
                skill: skill,
                version: version,
                changelog: changelog,
                tags: tags
            )
            _ = try Self.runProcess(
                executable: bunx,
                arguments: args
            )
        }.value

        let hash = try await Task.detached { try Self.computeSkillHash(for: skill) }.value
        savePublishState(for: skill.name, hash: hash)
    }

    func fetchClawdhubStatus() async -> CliStatus {
        await Task.detached {
            guard let bunx = Self.resolveBunxPath() else {
                return CliStatus(
                    isInstalled: false,
                    isLoggedIn: false,
                    username: nil,
                    errorMessage: "Bun is not installed."
                )
            }

            do {
                let whoami = try Self.runProcess(
                    executable: bunx,
                    arguments: ["clawdhub@latest", "whoami"]
                )
                let username = Self.lastNonEmptyLine(from: whoami)
                return CliStatus(
                    isInstalled: true,
                    isLoggedIn: !username.isEmpty,
                    username: username.isEmpty ? nil : username,
                    errorMessage: nil
                )
            } catch {
                return CliStatus(
                    isInstalled: true,
                    isLoggedIn: false,
                    username: nil,
                    errorMessage: nil
                )
            }
        }.value
    }


    private func normalizeSelectionToPreferredPlatform() {
        guard let selectedSkillID,
              let selected = skills.first(where: { $0.id == selectedSkillID }) else {
            return
        }

        let slug = selected.name
        let candidates = skills.filter { $0.name == slug }
        guard candidates.count > 1 else { return }

        let preferred = candidates.first(where: { $0.platform == .codex }) ?? candidates.first
        if let preferred, preferred.id != selectedSkillID {
            self.selectedSkillID = preferred.id
        }
    }

    func installRemoteSkill(
        _ skill: RemoteSkill,
        client: RemoteSkillClient,
        destinations: Set<SkillPlatform>
    ) async throws {
        guard !destinations.isEmpty else {
            throw NSError(domain: "RemoteSkill", code: 3)
        }

        let fileManager = FileManager.default
        let zipURL = try await client.download(skill.slug, skill.latestVersion)

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? fileManager.removeItem(at: tempRoot)
            try? fileManager.removeItem(at: zipURL)
        }

        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try unzip(zipURL, to: tempRoot)

        guard let skillRoot = findSkillRoot(in: tempRoot) else {
            throw NSError(domain: "RemoteSkill", code: 1)
        }

        for platform in destinations {
            let destinationRoot = platform.rootURL
            try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

            let finalURL = destinationRoot.appendingPathComponent(skill.slug)
            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.removeItem(at: finalURL)
            }
            try fileManager.copyItem(at: skillRoot, to: finalURL)
            try writeClawdhubOrigin(
                at: finalURL,
                slug: skill.slug,
                version: skill.latestVersion
            )
        }

        await loadSkills()
        if let platform = destinations.first {
            selectedSkillID = "\(platform.storageKey)-\(skill.slug)"
        }
    }

    private func unzip(_ url: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, destination.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "RemoteSkill", code: 2)
        }
    }

    nonisolated private static func publishArguments(
        skill: Skill,
        version: String,
        changelog: String,
        tags: [String]
    ) -> [String] {
        var args = [
            "clawdhub@latest",
            "publish",
            skill.folderURL.path,
            "--version",
            version,
        ]

        if !changelog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["--changelog", changelog])
        }

        let cleanedTags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !cleanedTags.isEmpty {
            args.append(contentsOf: ["--tags", cleanedTags.joined(separator: ",")])
        }

        return args
    }

    nonisolated private static func publishVersion(for latest: String?, bump: PublishBump) -> String {
        guard let latest, let next = bumpVersion(latest, bump: bump) else {
            return "1.0.0"
        }
        return next
    }

    nonisolated private static func bumpVersion(_ current: String, bump: PublishBump) -> String? {
        let parts = current.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var major = parts[0]
        var minor = parts[1]
        var patch = parts[2]

        switch bump {
        case .major:
            major += 1
            minor = 0
            patch = 0
        case .minor:
            minor += 1
            patch = 0
        case .patch:
            patch += 1
        }

        return "\(major).\(minor).\(patch)"
    }

    func nextVersion(from current: String, bump: PublishBump) -> String? {
        Self.bumpVersion(current, bump: bump)
    }

    nonisolated private static func resolveBunxPath() -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.bun/bin/bunx",
            "/opt/homebrew/bin/bunx",
            "/usr/local/bin/bunx",
            "/usr/bin/bunx"
        ]

        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return path
        }

        if let which = try? runProcess(executable: "/usr/bin/env", arguments: ["which", "bunx"]) {
            let trimmed = which.trimmingCharacters(in: .whitespacesAndNewlines)
            if fileManager.isExecutableFile(atPath: trimmed) {
                return trimmed
            }
        }

        return nil
    }

    nonisolated private static func lastNonEmptyLine(from output: String) -> String {
        let cleaned = output.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[mK]",
            with: "",
            options: .regularExpression
        )
        return cleaned
            .components(separatedBy: .newlines)
            .reversed()
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated private static func runProcess(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = defaultEnvironment()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
        let combinedOutput = [output, errorOutput]
            .filter { !$0.isEmpty }
            .joined(separator: output.isEmpty || errorOutput.isEmpty ? "" : "\n")

        if process.terminationStatus != 0 {
            throw NSError(domain: "ClawdhubPublish", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: errorOutput.isEmpty ? output : errorOutput
            ])
        }

        return combinedOutput
    }

    nonisolated private static func defaultEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        if environment["HOME"]?.isEmpty ?? true {
            environment["HOME"] = home
        }

        let standardPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        if let existing = environment["PATH"], !existing.isEmpty {
            let parts = existing.split(separator: ":").map(String.init)
            let missing = standardPaths.filter { !parts.contains($0) }
            if !missing.isEmpty {
                environment["PATH"] = parts.joined(separator: ":") + ":" + missing.joined(separator: ":")
            }
        } else {
            environment["PATH"] = standardPaths.joined(separator: ":")
        }

        if environment["BUN_INSTALL"]?.isEmpty ?? true {
            environment["BUN_INSTALL"] = "\(home)/.bun"
        }

        return environment
    }

    private func publishStateDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexSkillManager")
            .appendingPathComponent("skill-state")
    }

    private func publishStateURL(for slug: String) -> URL {
        publishStateDirectory().appendingPathComponent("\(slug).json")
    }

    private func loadPublishState(for slug: String) -> PublishState? {
        let url = publishStateURL(for: slug)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PublishState.self, from: data)
    }

    private func savePublishState(for slug: String, hash: String) {
        let dir = publishStateDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let state = PublishState(lastPublishedHash: hash, lastPublishedAt: Date())
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: publishStateURL(for: slug), options: [.atomic])
        }
    }

    nonisolated private static func computeSkillHash(for skill: Skill) throws -> String {
        let fileManager = FileManager.default
        let rootURL = skill.folderURL

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ""
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let path = fileURL.path
            if path.contains("/.git/") || path.contains("/.clawdhub/") {
                continue
            }
            if fileURL.lastPathComponent == ".DS_Store" {
                continue
            }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append(fileURL)
        }

        files.sort { $0.path < $1.path }

        var hasher = SHA256()
        for fileURL in files {
            guard let data = try? Data(contentsOf: fileURL),
                  String(data: data, encoding: .utf8) != nil else {
                continue
            }
            let relative = fileURL.path.replacingOccurrences(of: rootURL.path, with: "")
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: data)
            hasher.update(data: Data([0]))
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func findSkillRoot(in rootURL: URL) -> URL? {
        let fileManager = FileManager.default
        let directSkill = rootURL.appendingPathComponent("SKILL.md")
        if fileManager.fileExists(atPath: directSkill.path) {
            return rootURL
        }

        guard let children = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidateDirs = children.compactMap { url -> URL? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            let skillFile = url.appendingPathComponent("SKILL.md")
            return fileManager.fileExists(atPath: skillFile.path) ? url : nil
        }

        if candidateDirs.count == 1 {
            return candidateDirs[0]
        }

        return nil
    }

    private func writeClawdhubOrigin(at skillRoot: URL, slug: String, version: String?) throws {
        let originDir = skillRoot
            .appendingPathComponent(".clawdhub", isDirectory: true)
        try FileManager.default.createDirectory(at: originDir, withIntermediateDirectories: true)

        let originURL = originDir.appendingPathComponent("origin.json")
        let payload: [String: Any] = [
            "slug": slug,
            "version": version ?? "latest",
            "source": "clawdhub",
            "installedAt": Int(Date().timeIntervalSince1970)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: originURL, options: [.atomic])
    }

    private func loadSkills(from baseURL: URL, platform: SkillPlatform) throws -> [Skill] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: baseURL.path) else {
            return []
        }

        let items = try fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return items.compactMap { url -> Skill? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }

            let name = url.lastPathComponent
            let skillFileURL = url.appendingPathComponent("SKILL.md")
            let hasSkillFile = fileManager.fileExists(atPath: skillFileURL.path)

            guard hasSkillFile else { return nil }

            let markdown = (try? String(contentsOf: skillFileURL, encoding: .utf8)) ?? ""
            let metadata = parseMetadata(from: markdown)

            let references = referenceFiles(in: url.appendingPathComponent("references"))
            let referencesCount = references.count
            let assetsCount = countEntries(in: url.appendingPathComponent("assets"))
            let scriptsCount = countEntries(in: url.appendingPathComponent("scripts"))
            let templatesCount = countEntries(in: url.appendingPathComponent("templates"))

            return Skill(
                id: "\(platform.storageKey)-\(name)",
                name: name,
                displayName: formatTitle(metadata.name ?? name),
                description: metadata.description ?? "No description available.",
                platform: platform,
                folderURL: url,
                skillMarkdownURL: skillFileURL,
                references: references,
                stats: SkillStats(
                    references: referencesCount,
                    assets: assetsCount,
                    scripts: scriptsCount,
                    templates: templatesCount
                )
            )
        }
    }
}
