import Foundation

let appLanguageKey = "app.language"

func resolvedLanguage() -> String {
    let saved = UserDefaults.standard.string(forKey: appLanguageKey) ?? "system"
    if saved == "system" {
        return (Locale.preferredLanguages.first?.hasPrefix("zh") ?? false) ? "zh" : "en"
    }
    return saved
}

func L(_ chinese: String, _ english: String) -> String {
    resolvedLanguage() == "zh" ? chinese : english
}
