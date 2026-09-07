import SwiftUI

/// Scratch notes: the list on the left, the note itself on the right.
struct NotesPane: View {
    @ObservedObject var notes: NoteStore
    @ObservedObject var privacy: PrivacyMode
    /// Whether the panel holds the keyboard, so the editor can follow it.
    @Binding var wantsKeyboard: Bool

    @FocusState private var focused: Bool
    @FocusState private var focusedItem: ChecklistItem.ID?

    /// Per note, like the rows in the other tabs. A curtain over the whole tab
    /// would also cover the only thing here that is not the text — which note
    /// is which — and leave no way to pick one without uncovering it.
    private func hidden(_ id: Note.ID) -> Bool { privacy.hides(.notes, "note.\(id)") }

    private var selectedHidden: Bool {
        guard let id = notes.selected else { return false }
        return hidden(id)
    }

    private var selectedNote: Note? {
        guard let id = notes.selected else { return nil }
        return notes.notes.first(where: { $0.id == id })
    }

    var body: some View {
        HStack(spacing: 10) {
            list
            editor
        }
        .padding(.top, 2)
        // Arriving means arriving to type. With nothing to select, an empty
        // note is created on the spot: a welcome screen with a button would be
        // slower than the editor window this tab exists to replace.
        .onAppear {
            if notes.notes.isEmpty {
                create(checklist: false)
            } else if notes.selected == nil {
                notes.selected = notes.notes.first?.id
            }
        }
        .onChange(of: wantsKeyboard) { _, wants in
            focused = wants
            if wants, let note = selectedNote, note.isChecklist {
                focusedItem = note.items.first?.id
            }
        }
        .onChange(of: notes.selected) { _, _ in
            if let note = selectedNote, note.isChecklist {
                focusedItem = note.items.first?.id
            }
        }
    }

    /// What lies over the editor while the chosen note is covered. The editor
    /// itself stays where it is underneath — see the note at the editor.
    private var editorCover: some View {
        ZStack {
            SpoilerField(seed: seed(for: notes.selected))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if let id = notes.selected {
                Button { privacy.reveal("note.\(id)") } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                }
                .buttonStyle(.plain)
                .help(localized("Show"))
            }
        }
    }

    private func seed(for id: Note.ID?) -> UInt64 {
        guard let id else { return 0x9E3779B97F4A7C05 }
        return UInt64(bitPattern: Int64(id.hashValue))
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                addButton(title: localized("New Note"), checklist: false)
                Button {
                    create(checklist: true)
                } label: {
                    Image(systemName: "checklist")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 28, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Theme.surface)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(localized("New Todo List"))
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 3) {
                    ForEach(notes.ordered) { note in
                        NoteRow(
                            note: note,
                            isSelected: notes.selected == note.id,
                            hidden: hidden(note.id),
                            showsEye: privacy.covers(.notes),
                            toggleReveal: { privacy.toggle("note.\(note.id)") },
                            select: {
                                notes.selected = note.id
                                focused = true
                                if note.isChecklist {
                                    focusedItem = note.items.first?.id
                                }
                            },
                            pin: { notes.togglePin(note.id) },
                            delete: {
                                notes.remove(note.id)
                                // The tab's invariant: there is always a note
                                // under the caret.
                                if notes.notes.isEmpty { notes.add() }
                            }
                        )
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .frame(width: 170)
    }

    private func addButton(title: String, checklist: Bool) -> some View {
        Button {
            create(checklist: checklist)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.surface)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func create(checklist: Bool) {
        notes.add(checklist: checklist)
        // A note created by hand is uncovered from the start: it is being
        // written this second, by the person looking at it, and asking them
        // to uncover their own blank page before typing into it would be a
        // riddle, not a precaution.
        if let id = notes.selected { privacy.reveal("note.\(id)") }
        focused = true
        if checklist, let item = notes.notes.first?.items.first {
            focusedItem = item.id
        }
    }

    // MARK: - Editor

    private var currentText: String {
        selectedNote?.text ?? ""
    }

    private var editorBinding: Binding<String> {
        Binding(
            get: { currentText },
            set: { text in
                guard let id = notes.selected else { return }
                notes.update(id, text: text)
            }
        )
    }

    @ViewBuilder
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if let note = selectedNote, note.isChecklist {
                checklistEditor(for: note)
            } else {
                plainEditor
            }
        }
        // Covered, the editor is faded out and switched off rather than taken
        // out of the view tree. Removing it is what the long note above warns
        // against: the editor is deliberately mounted once for the whole pane,
        // and tearing down a focused text view hands SwiftUI's focus cleanup a
        // chance to fire after the next request. Alpha zero draws no glyphs —
        // there is nothing composited to recover — and `disabled` makes sure a
        // keystroke cannot land in something nobody can read.
        .opacity(selectedHidden ? 0 : 1)
        .disabled(selectedHidden)
        .overlay {
            if selectedHidden { editorCover }
        }
        // Above the curtain on purpose: a covered note still copies, the same
        // way a covered row in the other tabs does. Using what is hidden must
        // not require showing it first.
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                if let note = selectedNote {
                    Button {
                        notes.setChecklist(note.id, !note.isChecklist)
                        if !note.isChecklist {
                            DispatchQueue.main.async {
                                focusedItem = notes.notes.first(where: { $0.id == note.id })?.items.first?.id
                            }
                        } else {
                            focused = true
                        }
                    } label: {
                        Image(systemName: note.isChecklist ? "checklist" : "text.alignleft")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(note.isChecklist ? .white : Theme.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(note.isChecklist ? Theme.surfaceHover : Theme.surface))
                    }
                    .buttonStyle(.plain)
                    .help(localized(note.isChecklist ? "Convert to Note" : "Convert to Todo List"))
                }
                if let note = selectedNote, !note.copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    CopyNoteButton(text: note.copyText)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private var plainEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: editorBinding)
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .tint(Theme.secondary)
                .focused($focused)
                // The editor insets its text by a few points of its own; pull
                // that back so the first character lines up with the padding.
                .padding(.leading, -5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // One editor for all notes, deliberately NOT remounted per
                // note. A remount (`.id(selected)`) tears the focused view
                // down, and SwiftUI's cleanup for "the focused view
                // disappeared" clears the FocusState at a moment of its own
                // choosing — racing, and regularly beating, every way of
                // re-requesting focus. With one long-lived editor the text
                // swaps inside a view that never dies.
                .onAppear {
                    DispatchQueue.main.async { focused = wantsKeyboard }
                }
                .onKeyPress(.escape) {
                    wantsKeyboard = false
                    return .handled
                }

            if currentText.isEmpty {
                Text(localized("Jot something down…"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tertiary)
                    .allowsHitTesting(false)
            }
        }
    }

    private func checklistEditor(for note: Note) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(note.items) { item in
                    ChecklistRow(
                        item: item,
                        text: Binding(
                            get: {
                                notes.notes
                                    .first(where: { $0.id == note.id })?
                                    .items.first(where: { $0.id == item.id })?
                                    .text ?? ""
                            },
                            set: { notes.updateItem(note.id, itemID: item.id, text: $0) }
                        ),
                        toggle: { notes.toggleItem(note.id, itemID: item.id) },
                        onSubmit: {
                            if let newID = notes.addItem(note.id, after: item.id) {
                                focusedItem = newID
                            }
                        },
                        onBackspaceEmpty: {
                            let items = notes.notes.first(where: { $0.id == note.id })?.items ?? []
                            guard items.count > 1 else { return }
                            let index = items.firstIndex(where: { $0.id == item.id }) ?? 0
                            let previous = index > 0 ? items[index - 1].id : items.first?.id
                            notes.removeItem(note.id, itemID: item.id)
                            focusedItem = previous
                        }
                    )
                    .focused($focusedItem, equals: item.id)
                }

                Button {
                    if let newID = notes.addItem(note.id) {
                        focusedItem = newID
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                        Text(localized("Add item"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.tertiary)
                    .padding(.leading, 2)
                    .padding(.top, 4)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onKeyPress(.escape) {
            wantsKeyboard = false
            return .handled
        }
    }
}

// MARK: - Checklist row

private struct ChecklistRow: View {
    let item: ChecklistItem
    @Binding var text: String
    let toggle: () -> Void
    let onSubmit: () -> Void
    let onBackspaceEmpty: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.done ? .white.opacity(0.75) : Theme.secondary)
            }
            .buttonStyle(.plain)

            TextField("", text: $text, prompt: Text(localized("What needs doing…")).foregroundStyle(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(item.done ? Theme.tertiary : .white)
                .strikethrough(item.done, color: Theme.tertiary)
                .onSubmit(onSubmit)
                .onKeyPress(.delete) {
                    guard text.isEmpty else { return .ignored }
                    onBackspaceEmpty()
                    return .handled
                }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Sidebar row

private struct NoteRow: View {
    let note: Note
    let isSelected: Bool
    let hidden: Bool
    let showsEye: Bool
    let toggleReveal: () -> Void
    let select: () -> Void
    let pin: () -> Void
    let delete: () -> Void

    @State private var hovering = false

    /// Shown in place of the first line while the note is covered. A note has
    /// no name of its own — the list borrows its opening words, which is the
    /// text itself — so the time it was last touched stands in: enough to tell
    /// two notes apart and to recognise the one just written, and it says
    /// nothing about what is in them.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("Hm")
        return f
    }()

    var body: some View {
        HStack(spacing: 6) {
            if note.isChecklist {
                Image(systemName: "checklist")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.secondary : Theme.tertiary)
                    .frame(width: 12)
            }

            if hidden {
                Text(Self.clock.string(from: note.edited))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(isSelected ? Theme.secondary : Theme.tertiary)
                    // The dust beside it asks for every point of the row and
                    // asks with a higher layout priority, so without this the
                    // time is squeezed to nothing — which is the whole reason
                    // it is there. Verified by looking: the covered rows came
                    // out with a blank margin where the time should have been.
                    .fixedSize()
                SpoilerText(
                    text: preview,
                    hidden: true,
                    height: 11,
                    seed: UInt64(bitPattern: Int64(note.id.hashValue))
                )
            } else {
                Text(preview)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .white : Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if let progress = note.checklistProgress, !hidden {
                Text("\(progress.done)/\(progress.total)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            if hovering, showsEye {
                RevealEye(hidden: hidden, action: toggleReveal)
            }
            if hovering || note.pinned {
                Button(action: pin) {
                    Image(systemName: note.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(note.pinned ? Color.white.opacity(0.85) : Theme.secondary)
                }
                .buttonStyle(.plain)
                .help(localized(note.pinned ? "Unpin" : "Pin"))
            }
            if hovering {
                Button(action: delete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help(localized("Delete"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Theme.surfaceHover : hovering ? Theme.surface : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(Theme.contentAnimation, value: hovering)
    }

    /// The first line stands in for a title — notes here are too short-lived
    /// to deserve naming as a separate step.
    private var preview: String {
        let line = note.preview
        if line.isEmpty {
            return localized(note.isChecklist ? "Empty todo list" : "Empty note")
        }
        return line
    }
}

private struct CopyNoteButton: View {
    let text: String

    var body: some View {
        CopyButton {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
}
