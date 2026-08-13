import SwiftUI

/// The name dictionary as removable pills instead of one comma-separated
/// string. Comma-separated text hid duplicates and made a single name
/// awkward to delete; a pill is a thing you can see and dismiss.
struct NameDictionaryField: View {
    @Binding var names: [String]
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !names.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(names, id: \.self) { name in
                        NamePill(name: name) { remove(name) }
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Add a name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(commitDraft)
                    .onChange(of: draft) { _, new in
                        // Typing or pasting a comma commits everything before it,
                        // so pasted lists still land as separate pills.
                        if new.contains(",") { commitDraft() }
                    }
                Button("Add", action: commitDraft)
                    .disabled(pendingNames.isEmpty)
            }
        }
    }

    /// Whatever the draft currently resolves to: trimmed, split on commas,
    /// empties dropped, and already-present names ignored.
    private var pendingNames: [String] {
        draft.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { candidate in
                !candidate.isEmpty && !names.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
            }
    }

    private func commitDraft() {
        for name in pendingNames where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            names.append(name)
        }
        draft = ""
        fieldFocused = true
    }

    private func remove(_ name: String) {
        names.removeAll { $0 == name }
    }
}

private struct NamePill: View {
    let name: String
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.callout)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(hovering ? Color.primary.opacity(0.7) : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(name)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.accentColor.opacity(hovering ? 0.25 : 0.15))
        )
        .overlay(
            Capsule().strokeBorder(Color.accentColor.opacity(0.25))
        )
        .onHover { hovering = $0 }
    }
}

/// Minimal wrapping layout — pills flow left to right and wrap to the next
/// line. SwiftUI still has no built-in flow container.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = layout(subviews: subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layout(subviews: subviews, width: bounds.width)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(indices: [], y: current.y + current.height + spacing, width: 0, height: 0)
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
