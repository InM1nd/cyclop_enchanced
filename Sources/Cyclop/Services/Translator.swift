import AppKit
import Translation

/// On-device translation. Source and target are named languages the user
/// picked — Auto on the source still guesses from script, because a single
/// word is too short for Apple's identifier and "привет" comes back Bulgarian.
@MainActor
final class Translator: ObservableObject {
    static let russian = Locale.Language(identifier: "ru")
    static let english = Locale.Language(identifier: "en")

    /// Languages Translation.framework commonly has packs for. The pane will
    /// still say so if a pair is missing — this is the menu, not a promise.
    static let catalogIDs: [String] = [
        "en", "ru", "uk", "de", "fr", "es", "it", "pt", "pl", "nl",
        "tr", "ar", "zh-Hans", "zh-Hant", "ja", "ko", "th", "vi", "id", "hi",
    ]
    static let catalog: [Locale.Language] = catalogIDs.map { Locale.Language(identifier: $0) }

    struct Route: Equatable {
        var source: Locale.Language
        var target: Locale.Language
    }

    struct Request: Equatable {
        var text: String
        var attempt: Int
        var sourceID: String
        var targetID: String
    }

    @Published var input = ""
    @Published private(set) var output = ""
    @Published private(set) var failure: String?
    @Published private(set) var needsDownload = false
    @Published private(set) var isDownloading = false
    /// Empty string means Auto — script picks the source.
    @Published private(set) var sourceID: String
    @Published private(set) var targetID: String

    private var attempt = 0
    private var pendingDownload = false

    private static let sourceKey = "translator.source"
    private static let targetKey = "translator.target"

    init() {
        let defaults = UserDefaults.standard
        let storedSource = defaults.string(forKey: Self.sourceKey) ?? ""
        sourceID = storedSource
        let storedTarget = defaults.string(forKey: Self.targetKey) ?? Self.id(Self.russian)
        targetID = storedTarget.isEmpty ? Self.id(Self.russian) : storedTarget
    }

    var request: Request {
        Request(text: input, attempt: attempt, sourceID: sourceID, targetID: targetID)
    }
    var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isSourceAuto: Bool { sourceID.isEmpty }
    var route: Route { Route(source: resolvedSource, target: resolvedTarget) }

    var resolvedTarget: Locale.Language { language(from: targetID) ?? Self.russian }

    var resolvedSource: Locale.Language {
        if let pinned = language(from: sourceID) { return pinned }
        let detected = Self.detectSource(for: trimmed)
        if Self.id(detected) == Self.id(resolvedTarget) {
            return Self.id(resolvedTarget) == Self.id(Self.english) ? Self.russian : Self.english
        }
        return detected
    }

    func setSource(_ language: Locale.Language?) {
        sourceID = language.map(Self.id) ?? ""
        UserDefaults.standard.set(sourceID, forKey: Self.sourceKey)
        retry()
    }

    func setTarget(_ language: Locale.Language) {
        targetID = Self.id(language)
        UserDefaults.standard.set(targetID, forKey: Self.targetKey)
        if !isSourceAuto, sourceID == targetID {
            sourceID = ""
            UserDefaults.standard.set(sourceID, forKey: Self.sourceKey)
        }
        retry()
    }

    func swap() {
        let newTarget = resolvedSource
        let newSource = resolvedTarget
        sourceID = Self.id(newSource)
        targetID = Self.id(newTarget)
        UserDefaults.standard.set(sourceID, forKey: Self.sourceKey)
        UserDefaults.standard.set(targetID, forKey: Self.targetKey)
        retry()
    }

    /// Russian / other Cyrillic → ru, Hangul → ko, kana → ja, Han → zh-Hans,
    /// Arabic → ar, Thai → th, Devanagari → hi, everything else → en.
    static func detectSource(for text: String) -> Locale.Language {
        let scalars = text.unicodeScalars
        func any(_ range: ClosedRange<UInt32>) -> Bool {
            scalars.contains { range.contains($0.value) }
        }
        if any(0x0400...0x04FF) { return russian }
        if any(0xAC00...0xD7AF) { return Locale.Language(identifier: "ko") }
        if any(0x3040...0x30FF) { return Locale.Language(identifier: "ja") }
        if any(0x4E00...0x9FFF) { return Locale.Language(identifier: "zh-Hans") }
        if any(0x0600...0x06FF) { return Locale.Language(identifier: "ar") }
        if any(0x0E00...0x0E7F) { return Locale.Language(identifier: "th") }
        if any(0x0900...0x097F) { return Locale.Language(identifier: "hi") }
        return english
    }

    func retry() {
        attempt += 1
    }

    func requestDownload() {
        pendingDownload = true
        retry()
    }

    func clear() {
        output = ""
        failure = nil
        needsDownload = false
    }

    func reset() {
        input = ""
        clear()
    }

    func run(_ session: TranslationSession) async {
        let text = trimmed
        guard !text.isEmpty else { clear(); return }
        guard let source = session.sourceLanguage, let target = session.targetLanguage else { return }

        var status = await LanguageAvailability().status(from: source, to: target)

        if status == .supported, pendingDownload {
            pendingDownload = false
            NSApp.activate(ignoringOtherApps: true)
            isDownloading = true
            _ = await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await session.prepareTranslation() }
                group.addTask { try? await Task.sleep(for: .seconds(20)) }
                await group.next()
                group.cancelAll()
            }
            isDownloading = false
            guard !Task.isCancelled else { return }
            status = await LanguageAvailability().status(from: source, to: target)
        }

        guard status == .installed else {
            output = ""
            needsDownload = status == .supported
            failure = needsDownload
                ? localized("The %@ → %@ language pack is not installed.", Self.name(source), Self.name(target))
                : localized("macOS does not translate this pair of languages.")
            return
        }

        do {
            let response = try await session.translate(text)
            guard !Task.isCancelled else { return }
            output = response.targetText
            failure = nil
            needsDownload = false
        } catch {
            guard !Task.isCancelled else { return }
            output = ""
            needsDownload = false
            failure = error.localizedDescription
        }
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
    }

    static func name(_ language: Locale.Language) -> String {
        let locale = Locale(identifier: appLanguage)
        let raw = locale.localizedString(forIdentifier: language.maximalIdentifier)
            ?? language.languageCode.flatMap { locale.localizedString(forLanguageCode: $0.identifier) }
            ?? language.languageCode?.identifier.uppercased()
            ?? "?"
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    static func code(_ language: Locale.Language) -> String {
        language.languageCode?.identifier.uppercased() ?? "?"
    }

    /// Catalog key if we have one (`zh-Hans`, `en`), otherwise the maximal id.
    /// Storing the short key keeps the menu checkmark matching after relaunch.
    static func id(_ language: Locale.Language) -> String {
        let maximal = language.maximalIdentifier
        return catalogIDs.first { Locale.Language(identifier: $0).maximalIdentifier == maximal }
            ?? language.languageCode?.identifier
            ?? maximal
    }

    static func openLanguageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func language(from id: String) -> Locale.Language? {
        guard !id.isEmpty else { return nil }
        return Locale.Language(identifier: id)
    }
}
