import Foundation

// MARK: - Cihaz

enum DeviceState: String {
    case ready = "device"
    case offline
    case unauthorized
    case unknown

    var label: String {
        switch self {
        case .ready: return "Hazır"
        case .offline: return "Çevrimdışı"
        case .unauthorized: return "İzin bekliyor"
        case .unknown: return "Bilinmiyor"
        }
    }

    var isControllable: Bool { self == .ready }
}

enum ConnectionKind: String {
    case wifi
    case usb

    var label: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .usb: return "USB"
        }
    }
}

struct AndroidDevice: Identifiable, Hashable {
    let serial: String
    var state: DeviceState
    var model: String?
    var product: String?
    var transportID: String?

    var id: String { serial }

    var connection: ConnectionKind {
        serial.contains(":") || serial.hasPrefix("adb-") ? .wifi : .usb
    }

    /// UI'da görünen ad: model adı varsa o, yoksa seri numarası.
    var displayName: String {
        if let model, !model.isEmpty {
            return model.replacingOccurrences(of: "_", with: " ")
        }
        return serial
    }

    var subtitle: String {
        var parts: [String] = [connection.label]
        if let product, !product.isEmpty { parts.append(product) }
        parts.append(serial)
        return parts.joined(separator: " · ")
    }
}

// MARK: - mDNS servisi

struct MDNSService: Identifiable, Hashable {
    let instance: String
    let serviceType: String
    let endpoint: String   // ip:port

    var id: String { "\(instance)|\(serviceType)|\(endpoint)" }

    var host: String { endpoint.split(separator: ":").first.map(String.init) ?? endpoint }
    var port: Int { Int(endpoint.split(separator: ":").last.map(String.init) ?? "") ?? 0 }

    /// `_adb-tls-pairing._tcp` — yalnızca cihazda eşleştirme penceresi açıkken yayınlanır.
    var isPairingService: Bool { serviceType.contains("pairing") }
    /// `_adb-tls-connect._tcp` — güvenli bağlantı; bu bilgisayarla eşleşme ister.
    var isSecureConnect: Bool { serviceType.contains("tls-connect") }
    /// `_adb._tcp` — eski tip TCP; eşleştirme gerektirmez.
    var isLegacyConnect: Bool { serviceType == "_adb._tcp" }
}

// MARK: - Android uygulaması

struct AndroidApp: Identifiable, Hashable {
    let packageName: String
    /// Ana ekrandan açılan bileşen (`com.pkg/.Activity`) — varsa.
    var componentName: String? = nil
    /// APK'dan çözülmüş gerçek uygulama adı.
    var label: String? = nil

    var id: String { packageName }

    /// Gerçek ad yoksa paket adından türetilen okunur ad.
    var displayName: String {
        if let label, !label.isEmpty { return label }
        return Shell.friendlyName(fromPackage: packageName)
    }

    /// Gerçek adın kaynağı — arayüzde göstermek için.
    var isRealLabel: Bool { label != nil && !(label ?? "").isEmpty }
}

// MARK: - Klavye kodları (Android KeyEvent)

enum KeyCode: Int, CaseIterable, Identifiable {
    case home = 3
    case back = 4
    case dpadUp = 19
    case dpadDown = 20
    case dpadLeft = 21
    case dpadRight = 22
    case dpadCenter = 23
    case volumeUp = 24
    case volumeDown = 25
    case power = 26
    case menu = 82
    case search = 84
    case mediaPlayPause = 85
    case mediaPrevious = 88
    case mediaRewind = 89
    case mediaFastForward = 90
    case mediaNext = 87
    case mute = 164
    case tv = 170
    case guide = 172
    case info = 165
    case settings = 176
    case channelUp = 166
    case channelDown = 167

    var id: Int { rawValue }
}

/// `adb shell media dispatch` aksiyonları (aktif medya oturumuna gider).
enum MediaAction: String, CaseIterable, Identifiable {
    case play = "play"
    case pause = "pause"
    case playPause = "play-pause"
    case next = "next"
    case previous = "previous"
    case rewind = "rewind"
    case fastForward = "fast-forward"
    case stop = "stop"

    var id: String { rawValue }
}
