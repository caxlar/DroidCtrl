import Foundation

/// Küçük önizlemenin cihaza bindireceği yükü sınırlayan ayarlar.
///
/// Encoder yükü ≈ piksel × kare hızı. Önizleme ~300 pt genişliğinde olduğundan
/// yüksek çözünürlük kodlamak cihazda gereksiz CPU/ısı üretir.
enum PreviewQuality: String, CaseIterable, Identifiable {
    case low = "Düşük"
    case balanced = "Dengeli"

    var id: String { rawValue }

    /// Uzun kenardaki maksimum video çözünürlüğü.
    var maxSize: Int {
        switch self {
        case .low: return 480
        case .balanced: return 640
        }
    }

    var maxFPS: Int {
        switch self {
        case .low: return 12
        case .balanced: return 20
        }
    }

    var bitRate: Int {
        switch self {
        case .low: return 350_000
        case .balanced: return 800_000
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
    static let stopCelsius = 42
    /// Bu değerin üstünde kullanıcı uyarılır (°C).
    static let warnCelsius = 38
    /// Ne sıklıkla sıcaklık okunur (saniye).
    static let pollSeconds: TimeInterval = 15
}
