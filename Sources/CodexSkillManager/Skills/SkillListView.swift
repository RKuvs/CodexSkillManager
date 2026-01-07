import SwiftUI

struct SkillListView: View {
    let skills: [Skill]
    @Binding var selection: Skill.ID?
    @Environment(SkillStore.self) private var store

    var body: some View {
        List(selection: $selection) {
            ForEach(skills) { skill in
                SkillRowView(skill: skill)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await store.deleteSkills(ids: [skill.id]) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            .onDelete { offsets in
                let ids = offsets
                    .filter { skills.indices.contains($0) }
                    .map { skills[$0].id }
                Task { await store.deleteSkills(ids: ids) }
            }
        }
        .navigationTitle("Skills")
        .listStyle(.sidebar)
    }
}

private struct SkillRowView: View {
    let skill: Skill

    private var visibleTags: [String] {
        Array(skill.tagLabels.prefix(3))
    }

    private var overflowCount: Int {
        max(skill.tagLabels.count - visibleTags.count, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(skill.displayName)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(skill.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if !skill.tagLabels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(visibleTags, id: \.self) { tag in
                        TagView(text: tag)
                    }
                    if overflowCount > 0 {
                        TagView(text: "+\(overflowCount) more")
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct TagView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tagColor.opacity(0.18))
            )
    }

    private var tagColor: Color {
        let colors: [Color] = [
            .mint, .teal, .cyan, .blue, .indigo, .green, .orange
        ]
        let index = abs(text.hashValue) % colors.count
        return colors[index]
    }
}
