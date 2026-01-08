import SwiftUI

struct PublishSkillSheet: View {
    let skill: Skill
    let isPublishing: Bool
    let nextVersion: String
    @Binding var bump: PublishBump
    @Binding var changelog: String
    @Binding var tags: String
    let onCancel: () -> Void
    let onPublish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Publish Skill")
                    .font(.title.bold())
                Text("Push changes for \(skill.displayName) to Clawdhub.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Picker("Version bump", selection: $bump) {
                        ForEach(PublishBump.allCases) { bump in
                            Text(bump.label).tag(bump)
                        }
                    }
                    Text("Will publish v\(nextVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Changelog")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $changelog)
                        .frame(minHeight: 90)
                        .padding(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                }

            }

            Spacer()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                Spacer()
                Button(isPublishing ? "Publishing…" : "Publish") {
                    onPublish()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPublishing || changelog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 360)
    }
}
