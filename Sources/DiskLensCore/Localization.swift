import Foundation

/// Looks a user-facing string up in the app's Localizable.strings. The Chinese text is
/// the key; the English translations live in Localization/en.lproj. Outside the app
/// (the CLI, tests) there is no table and the Chinese text is returned as written.
public func L(_ value: String.LocalizationValue) -> String {
    let text = String(localized: value, bundle: .main)
    // English plurals are written as "^[%lld file](inflect: true)", which only
    // AttributedString resolves. Other strings skip it so Markdown characters stay as typed.
    guard text.contains("^[") else { return text }
    return String(AttributedString(localized: value, bundle: .main).characters)
}

public enum AppLanguage {
    /// Whether the app shows its English localization (the system or the user's choice).
    public static var isEnglish: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("en") ?? false
    }
}
