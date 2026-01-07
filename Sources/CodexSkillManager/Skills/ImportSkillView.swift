import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

private struct ImportCandidate {
    let rootURL: URL
    let skillFileURL: URL
    let skillName: String
    let markdown: String
    let temporaryRoot: URL?
}

struct ImportSkillView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillStore.self) private var store
    @State private var showingPicker = false
    @State private var candidate: ImportCandidate?
    @State private var status: Status = .idle
    @State private var errorMessage: String = ""

    private enum Status {
        case idle
        case validating
        case valid
        case invalid
        case importing
        case imported
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
            Spacer()
            actions
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 520)
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [.folder, .zip],
            allowsMultipleSelection: false
        ) { result in
            handlePick(result)
        }
        .onDisappear {
            cleanupCandidate()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Import Skill")
                .font(.title.bold())
            Text("Choose a skill folder or zip file to add it to your Codex skills.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .idle:
            emptyState
        case .validating:
            ProgressView("Validating…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .valid:
            preview
        case .invalid:
            invalidState
        case .importing:
            ProgressView("Importing…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .imported:
            successState
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Pick a folder or zip",
            systemImage: "tray.and.arrow.down",
            description: Text("We’ll verify it contains a SKILL.md and show a preview.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var invalidState: some View {
        ContentUnavailableView(
            "Not a valid skill",
            systemImage: "xmark.octagon",
            description: Text(errorMessage)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var successState: some View {
        ContentUnavailableView(
            "Imported",
            systemImage: "checkmark.seal",
            description: Text("The skill was added to your Codex skills folder.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var preview: some View {
        guard let candidate else {
            return AnyView(EmptyView())
        }

        return AnyView(
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(candidate.skillName)
                            .font(.title2.bold())
                        Text(candidate.rootURL.path)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Markdown(candidate.markdown)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )
        )
    }

    private var actions: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Choose…") {
                showingPicker = true
            }

            Button("Import") {
                Task { await importCandidate() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(status != .valid)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            status = .invalid
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else {
                status = .idle
                return
            }
            Task { await validate(url: url) }
        }
    }

    private func validate(url: URL) async {
        status = .validating
        errorMessage = ""
        cleanupCandidate()

        let resolved = url.standardizedFileURL
        let fileValues = try? resolved.resourceValues(forKeys: [.isDirectoryKey])

        if fileValues?.isDirectory == true {
            await validateFolder(resolved)
        } else if resolved.pathExtension.lowercased() == "zip" {
            await validateZip(resolved)
        } else {
            status = .invalid
            errorMessage = "Select a folder or .zip file."
        }
    }

    private func validateFolder(_ folderURL: URL) async {
        if let candidate = buildCandidate(from: folderURL, temporaryRoot: nil) {
            self.candidate = candidate
            status = .valid
        } else {
            status = .invalid
            errorMessage = "This folder doesn’t contain a SKILL.md file."
        }
    }

    private func validateZip(_ zipURL: URL) async {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        do {
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            try unzip(zipURL, to: tempRoot)

            if let candidate = buildCandidate(from: tempRoot, temporaryRoot: tempRoot) {
                self.candidate = candidate
                status = .valid
            } else {
                status = .invalid
                errorMessage = "This zip doesn’t contain a SKILL.md file."
                cleanupTemporaryRoot(tempRoot)
            }
        } catch {
            status = .invalid
            errorMessage = "Unable to read the zip file."
            cleanupTemporaryRoot(tempRoot)
        }
    }

    private func buildCandidate(from rootURL: URL, temporaryRoot: URL?) -> ImportCandidate? {
        guard let skillRoot = findSkillRoot(in: rootURL) else { return nil }
        let skillFileURL = skillRoot.appendingPathComponent("SKILL.md")
        guard let markdown = try? String(contentsOf: skillFileURL, encoding: .utf8) else { return nil }

        let skillName = skillRoot.lastPathComponent
        return ImportCandidate(
            rootURL: skillRoot,
            skillFileURL: skillFileURL,
            skillName: formatTitle(skillName),
            markdown: markdown,
            temporaryRoot: temporaryRoot
        )
    }

    private func importCandidate() async {
        guard let candidate else { return }
        status = .importing

        let destinationRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/skills/public")

        let finalURL = uniqueDestinationURL(
            base: destinationRoot.appendingPathComponent(candidate.rootURL.lastPathComponent)
        )

        do {
            try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }

            if candidate.temporaryRoot != nil {
                try FileManager.default.copyItem(at: candidate.rootURL, to: finalURL)
            } else {
                try FileManager.default.moveItem(at: candidate.rootURL, to: finalURL)
            }

            await store.loadSkills()
            status = .imported
        } catch {
            status = .invalid
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func uniqueDestinationURL(base: URL) -> URL {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: base.path) {
            return base
        }

        let baseName = base.lastPathComponent
        let parent = base.deletingLastPathComponent()
        var index = 1
        while true {
            let candidate = parent.appendingPathComponent("\(baseName)-\(index)")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private func cleanupCandidate() {
        if let temp = candidate?.temporaryRoot {
            cleanupTemporaryRoot(temp)
        }
        candidate = nil
    }

    private func cleanupTemporaryRoot(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func unzip(_ url: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, destination.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "ImportSkill", code: 1)
        }
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
}

private func formatTitle(_ title: String) -> String {
    let normalized = title
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
    return normalized
        .split(separator: " ")
        .map { $0.capitalized }
        .joined(separator: " ")
}
