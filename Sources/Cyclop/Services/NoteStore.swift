import AppKit

struct ChecklistItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var done: Bool
}

struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    /// Body of a plain note. Unused while `isChecklist` — the list lives in `items`.
    var text: String
    var edited: Date
    /// A checklist is one note that holds many tickable lines, not a note that
    /// is itself a single checkbox in the sidebar.
    var isChecklist: Bool
    var items: [ChecklistItem]
    /// At most one note is pinned; it stays at the top of the sidebar.
    var pinned: Bool

    /// First line worth showing in the sidebar.
    var preview: String {
        if isChecklist {
            let line = items
                .map(\.text)
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return line ?? ""
        }
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
    }

    var isBlank: Bool {
        if isChecklist {
            return items.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var checklistProgress: (done: Int, total: Int)? {
        guard isChecklist else { return nil }
        let total = items.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        guard total > 0 else { return nil }
        let done = items.filter { $0.done && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        return (done, total)
    }

    /// Plain copy payload — checklist lines without the markers.
    var copyText: String {
        if isChecklist {
            return items.map(\.text).joined(separator: "\n")
        }
        return text
    }

    enum CodingKeys: String, CodingKey {
        case id, text, edited, isChecklist, items, done, pinned
    }

    init(
        id: UUID,
        text: String,
        edited: Date,
        isChecklist: Bool = false,
        items: [ChecklistItem] = [],
        pinned: Bool = false
    ) {
        self.id = id
        self.text = text
        self.edited = edited
        self.isChecklist = isChecklist
        self.items = items
        self.pinned = pinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        edited = try container.decode(Date.self, forKey: .edited)
        var checklist = try container.decodeIfPresent(Bool.self, forKey: .isChecklist) ?? false
        var loadedItems = try container.decodeIfPresent([ChecklistItem].self, forKey: .items) ?? []

        // Short-lived `done: Bool?` experiment: a whole note was one checkbox.
        // Fold those into a one-item checklist so nothing the user typed is lost.
        if !checklist, let done = try container.decodeIfPresent(Bool.self, forKey: .done) {
            checklist = true
            if loadedItems.isEmpty {
                let lines = text.components(separatedBy: .newlines)
                let source = lines.isEmpty ? [""] : lines
                loadedItems = source.map { ChecklistItem(id: UUID(), text: String($0), done: done) }
            }
        }

        isChecklist = checklist
        items = loadedItems
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(edited, forKey: .edited)
        try container.encode(isChecklist, forKey: .isChecklist)
        try container.encode(items, forKey: .items)
        try container.encode(pinned, forKey: .pinned)
    }
}

/// Scratch notes: somewhere to put a thought down for an hour.
///
/// Deliberately not a notes app. No folders, no formatting, no search — for
/// that there are real editors. This replaces the unsaved buffer people keep
/// in one: a phone number from a call, half a link, a thought to come back to
/// — written fast, then deleted or carried off through the clipboard.
///
/// A note can also be a checklist: same slot in the sidebar, but the body is
/// a list of tickable lines instead of a free-text pad.
@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    /// Which note the editor shows. Lives here rather than in the pane so the
    /// choice survives the pane being unmounted with the panel.
    @Published var selected: Note.ID?

    private static let file = Support.file("notes.json")

    private let saves = DebouncedWrite()

    init() {
        load()
    }

    // MARK: - Editing

    /// A new empty note or checklist, selected and ready to type into. Newest
    /// on top, and the order never changes afterwards: a list that reshuffles
    /// itself on every edit loses the reader's place for tidiness nobody asked for.
    func add(checklist: Bool = false) {
        let note = Note(
            id: UUID(),
            text: "",
            edited: Date(),
            isChecklist: checklist,
            items: checklist ? [ChecklistItem(id: UUID(), text: "", done: false)] : []
        )
        notes.insert(note, at: 0)
        selected = note.id
        scheduleSave()
    }

    func update(_ id: Note.ID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].text = text
        notes[index].edited = Date()
        scheduleSave()
    }

    func updateItem(_ noteID: Note.ID, itemID: ChecklistItem.ID, text: String) {
        guard let noteIndex = notes.firstIndex(where: { $0.id == noteID }),
              let itemIndex = notes[noteIndex].items.firstIndex(where: { $0.id == itemID })
        else { return }
        notes[noteIndex].items[itemIndex].text = text
        notes[noteIndex].edited = Date()
        scheduleSave()
    }

    func toggleItem(_ noteID: Note.ID, itemID: ChecklistItem.ID) {
        guard let noteIndex = notes.firstIndex(where: { $0.id == noteID }),
              let itemIndex = notes[noteIndex].items.firstIndex(where: { $0.id == itemID })
        else { return }
        notes[noteIndex].items[itemIndex].done.toggle()
        notes[noteIndex].edited = Date()
        scheduleSave()
    }

    @discardableResult
    func addItem(_ noteID: Note.ID, after itemID: ChecklistItem.ID? = nil) -> ChecklistItem.ID? {
        guard let noteIndex = notes.firstIndex(where: { $0.id == noteID }) else { return nil }
        let item = ChecklistItem(id: UUID(), text: "", done: false)
        if let itemID, let at = notes[noteIndex].items.firstIndex(where: { $0.id == itemID }) {
            notes[noteIndex].items.insert(item, at: at + 1)
        } else {
            notes[noteIndex].items.append(item)
        }
        notes[noteIndex].edited = Date()
        scheduleSave()
        return item.id
    }

    func removeItem(_ noteID: Note.ID, itemID: ChecklistItem.ID) {
        guard let noteIndex = notes.firstIndex(where: { $0.id == noteID }) else { return }
        notes[noteIndex].items.removeAll { $0.id == itemID }
        if notes[noteIndex].items.isEmpty {
            notes[noteIndex].items = [ChecklistItem(id: UUID(), text: "", done: false)]
        }
        notes[noteIndex].edited = Date()
        scheduleSave()
    }

    /// Plain note ↔ checklist. Splits or joins lines so nothing typed is thrown away.
    func setChecklist(_ id: Note.ID, _ checklist: Bool) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[index].isChecklist != checklist else { return }
        if checklist {
            let lines = notes[index].text.components(separatedBy: .newlines)
            let source = (lines.isEmpty || notes[index].text.isEmpty) ? [""] : lines
            notes[index].items = source.map { ChecklistItem(id: UUID(), text: String($0), done: false) }
            notes[index].text = ""
            notes[index].isChecklist = true
        } else {
            notes[index].text = notes[index].items.map(\.text).joined(separator: "\n")
            notes[index].items = []
            notes[index].isChecklist = false
        }
        notes[index].edited = Date()
        scheduleSave()
    }

    func remove(_ id: Note.ID) {
        notes.removeAll { $0.id == id }
        if selected == id { selected = notes.first?.id }
        scheduleSave()
    }

    /// Exactly one note may be pinned. Pinning another clears the previous.
    func togglePin(_ id: Note.ID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let willPin = !notes[index].pinned
        for i in notes.indices { notes[i].pinned = false }
        if willPin { notes[index].pinned = true }
        scheduleSave()
    }

    /// Pinned note first; otherwise keep the store's order.
    var ordered: [Note] {
        let pinned = notes.filter(\.pinned)
        let rest = notes.filter { !$0.pinned }
        return pinned + rest
    }

    /// Called when the user leaves the tab: notes that never got any text
    /// sweep themselves out. They cost one hover to recreate, and a trail of
    /// blank cards is exactly the clutter a scratchpad exists to avoid.
    func leave() {
        notes.removeAll { $0.isBlank }
        if let selected, !notes.contains(where: { $0.id == selected }) {
            self.selected = notes.first?.id
        }
        flush()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.file),
              let stored = try? JSONDecoder().decode([Note].self, from: data) else { return }
        notes = stored
        selected = notes.first?.id
    }

    /// A moment after the typing pauses, not on every keystroke: the text
    /// lives in memory either way, and the file only has to be right by the
    /// time somebody could read it.
    private func scheduleSave() {
        saves.schedule { [weak self] in self?.persist() }
    }

    func flush() { saves.flush() }

    private func persist() {
        do {
            try JSONEncoder().encode(notes).write(to: Self.file, options: .atomic)
        } catch {
            NSLog("Cyclop: cannot write notes.json: \(error.localizedDescription)")
        }
    }
}
