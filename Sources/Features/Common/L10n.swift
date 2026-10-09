import Foundation

/// Two-language UI strings, decided once per launch from the system locale.
///
/// Deliberately not `Localizable.strings`: the app has exactly two audiences —
/// the Russian-speaking founder and English screenshots in the docs — and an
/// inline pair at the call site keeps both readable in code review, which a
/// key-file indirection does not.
enum L10n {
    /// One resolution for the whole app — previews included — so the UI can
    /// never end up half-translated. See `PreviewLanguage.system` for the
    /// order (an explicit `AppLanguage`, then the system's preferred language).
    static let isRussian = PreviewLanguage.system == .ru

    /// Locale for date formatters, so «чт» and «августа» match the UI language
    /// rather than the OS language.
    static let dateLocale = Locale(identifier: isRussian ? "ru_RU" : "en_US")

    static func s(_ en: String, _ ru: String) -> String {
        isRussian ? ru : en
    }
}
