//
//  LocalizationManager.swift — DroidDeck
//
//  String Catalog tabanlı çoklu dil yöneticisi.
//  SwiftUI'da `Text("key")` otomatik çalışır; runtime dil değiştirme için
//  AppleLanguages user defaults'ını günceller ve yeniden başlatma ister.
//

import Foundation
import SwiftUI

/// Uygulama dili yöneticisi.
///
/// - String Catalog (Localizable.xcstrings) kullanır.
/// - Dil değişikliği `UserDefaults.standard.set([lang], forKey: "AppleLanguages")`
///   ile yapılır; değişiklik bir sonraki uygulama başlangıcında aktif olur.
/// - Mevcut dil `Locale.current.language.languageCode?.identifier` ile okunur.
@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    /// Desteklenen diller.
    struct SupportedLanguage: Identifiable, Hashable {
        let id: String          // "en", "tr", "es", "zh-Hans", "de", "it"
        let code: String        // locale identifier
        let nativeName: String  // kendi dilinde adı
        let englishName: String // İngilizce adı
        let flag: String        // bayrak emoji
    }

    let supportedLanguages: [SupportedLanguage] = [
        SupportedLanguage(id: "en", code: "en", nativeName: "English", englishName: "English", flag: "🇺🇸"),
        SupportedLanguage(id: "tr", code: "tr", nativeName: "Türkçe", englishName: "Turkish", flag: "🇹🇷"),
        SupportedLanguage(id: "es", code: "es", nativeName: "Español", englishName: "Spanish", flag: "🇪🇸"),
        SupportedLanguage(id: "zh-Hans", code: "zh-Hans", nativeName: "中文", englishName: "Chinese", flag: "🇨🇳"),
        SupportedLanguage(id: "de", code: "de", nativeName: "Deutsch", englishName: "German", flag: "🇩🇪"),
        SupportedLanguage(id: "it", code: "it", nativeName: "Italiano", englishName: "Italian", flag: "🇮🇹"),
    ]

    /// Şu anki dil (UserDefaults'tan veya sistemden).
    @Published var currentLanguage: String {
        didSet {
            guard currentLanguage != oldValue else { return }
            UserDefaults.standard.set([currentLanguage], forKey: "AppleLanguages")
            UserDefaults.standard.synchronize()
            needsRestart = true
        }
    }

    /// Dil değiştirildiyse true — kullanıcıya yeniden başlatma uyarısı göster.
    @Published var needsRestart = false

    private init() {
        // Kaydedilmiş dil varsa onu, yoksa sistem dilini kullan.
        if let saved = UserDefaults.standard.array(forKey: "AppleLanguages")?.first as? String,
           supportedLanguages.map({ $0.id }).contains(saved) {
            currentLanguage = saved
        } else {
            let system = Locale.current.language.languageCode?.identifier ?? "en"
            currentLanguage = supportedLanguages.map({ $0.id }).contains(system) ? system : "en"
        }
    }

    /// Dil değiştir — hemen UI güncellenmez, yeniden başlatma gerekir.
    func setLanguage(_ code: String) {
        guard supportedLanguages.map({ $0.id }).contains(code) else { return }
        currentLanguage = code
    }

    /// Dil nesnesini getir.
    func language(for code: String) -> SupportedLanguage? {
        supportedLanguages.first { $0.id == code }
    }

    /// Mevcut dilin bayrağı.
    var currentFlag: String {
        language(for: currentLanguage)?.flag ?? "🌐"
    }

    /// Mevcut dilin yerel adı.
    var currentNativeName: String {
        language(for: currentLanguage)?.nativeName ?? "English"
    }

    /// Uygulamayı yeniden başlat (dil değişikliğinin etkili olması için).
    func restartApp() {
        needsRestart = false
        let url = URL(fileURLWithPath: Bundle.main.resourcePath!)
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [url.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// SwiftUI View extension — kolay erişim.
extension View {
    /// LocalizationManager'ı environment olarak ekle.
    func withLocalization() -> some View {
        self.environmentObject(LocalizationManager.shared)
    }
}

/// `Text("key")` yerine `L10n.key` kullanmak için statik erişim.
/// String Catalog SwiftUI'da `Text("key")` otomatik çalışır; bu sadece
/// kod tamamlama (autocomplete) için yardımcı bir namespace.
enum L10n {
    // App
    static let appName = "app_name"
    static let deviceScreen = "device_screen"
    static let scanDevices = "scan_devices"
    static let connect = "connect"
    static let disconnect = "disconnect"
    static let qualityLow = "quality_low"
    static let qualityBalanced = "quality_balanced"
    static let qualityHigh = "quality_high"
    static let previewPlay = "preview_play"
    static let previewStop = "preview_stop"
    static let battery = "battery"
    static let temperature = "temperature"
    static let settings = "settings"
    static let about = "about"
    static let deviceConnected = "device_connected"
    static let deviceReady = "device_ready"

    // Language
    static let language = "language"
    static let selectLanguage = "select_language"
    static let languageEnglish = "language_english"
    static let languageTurkish = "language_turkish"
    static let languageSpanish = "language_spanish"
    static let languageChinese = "language_chinese"
    static let languageGerman = "language_german"
    static let languageItalian = "language_italian"
    static let restartRequired = "restart_required"

    // Actions
    static let wakeUnlock = "wake_unlock"
    static let screenshot = "screenshot"
    static let toggleScreen = "toggle_screen"
    static let installApk = "install_apk"
    static let fileTransfer = "file_transfer"
    static let fullscreen = "fullscreen"
    static let refresh = "refresh"
    static let zoomIn = "zoom_in"
    static let zoomOut = "zoom_out"

    // Tools
    static let deviceInfo = "device_info"
    static let rebootDevice = "reboot_device"
    static let resetLabels = "reset_labels"
    static let restartAdb = "restart_adb"
    static let thermalProtection = "thermal_protection"
    static let thermalWarning = "thermal_warning"
    static let previewPlaceholder = "preview_placeholder"
    static let manualConnect = "manual_connect"
    static let ipPlaceholder = "ip_placeholder"
    static let enterFirst = "enter_first"
    static let connecting = "connecting"
    static let pairing = "pairing"
    static let pairingCode = "pairing_code"
    static let enterCode = "enter_code"
    static let cancel = "cancel"
    static let retry = "retry"
    static let error = "error"
    static let ok = "ok"
}