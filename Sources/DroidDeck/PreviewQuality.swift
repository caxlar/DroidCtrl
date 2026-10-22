import Foundation

/// Küçük önizlemenin cihaza bindireceği yükü sınırlayan ayarlar.
///
/// Encoder yükü ≈ piksel × kare hızı. Önizleme ~300 pt genişliğinde olduğundan
/// yüksek çözünürlük kodlamak cihazda gereksiz CPU/ısı üretir.
enum PreviewQuality: String, CaseIterable, Identifiable {
    case low = "Düşük"
    case balanced = "Dengeli"
    case high = "Yüksek (TV)"

    var id: String { rawValue }

    /// Uzun kenardaki maksimum video çözünürlüğü.
    /// 0 = sınır yok (cihazın yerel çözünürlüğü kullanılır).
    var maxSize: Int {
        switch self {
        case .low: return 480
        case .balanced: return 640
        case .high: return 0
        }
    }

    var maxFPS: Int {
        switch self {
        case .low: return 12
        case .balanced: return 20
        case .high: return 30
        }
    }

    var bitRate: Int {
        switch self {
        case .low: return 350_000
        case .balanced: return 800_000
        case .high: return 4_000_000
        }
    }

    /// Saniyede işlenen megapiksel — cihazdaki gerçek encoder yükü.
    var megapixelsPerSecond: Double {
        let scale = Double(maxSize) / 1280.0
        let width = 1280.0 * scale
        let height = 764.0 * scale
        return width * height * Double(maxFPS) / 1_000_000.0
    }

    var detail: String {
        "\(maxSize)px · \(maxFPS) fps · \(bitRate / 1000) kbps"
    }
}

/// Cihaz sıcaklığı güvenlik sınırları.
enum ThermalLimit {
    /// Bu değerin üstünde yayın otomatik durur (°C).
    static let stopCelsius = 45
    /// Bu değerin üstünde kullanıcı uyarılır (°C).
    static let warnCelsius = 40
    /// Ne sıklıkla sıcaklık okunur (saniye).
    static let pollSeconds: TimeInterval = 15
}
