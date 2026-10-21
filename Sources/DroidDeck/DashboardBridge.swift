//
//  DashboardBridge.swift — DroidDeck
//
//  Kullanıcının yeni arayüz tasarımını (TrebleDroidPixelDashboard) gerçek
//  DroidDeck işlevlerine bağlar.
//
//  Tasarım dosyası DEĞİŞTİRİLMEZ: `TDVisualActions` geri çağrıları buradan
//  doldurulur. Tasarımda olup henüz karşılığı olmayan düğmeler görünür kalır
//  (ileride geliştirilecek); olanlar gerçek işlevlere bağlanır.
//

import SwiftUI
import AppKit

@MainActor
final class DashboardBridge: ObservableObject {
    /// Gerçek `DeviceStore`. `DashboardHost` `.task` içinde bağlar
    /// (`@EnvironmentObject` init sırasında erişilemez).
    var store: DeviceStore
    /// Sol kenar çubuğu seçimi ("Cihazlar" / "Ayarlar" / "Hakkında").
    @Published var sidebarSection = "Cihazlar"

    init(store: DeviceStore) {
        self.store = store
    }

    // MARK: - Veri dönüşümü

    var visualDevices: [TDVisualDevice] {
        store.devices.map { device in
            TDVisualDevice(
                id: device.serial,
                address: device.serial,
                connected: device.state == .ready,
                nativePixelSize: store.videoSize == .zero
                    ? CGSize(width: 1280, height: 720)
                    : store.videoSize,
                battery: store.batteryLevel ?? 0,
                version: device.model ?? "Android"
            )
        }
    }

    var visualApps: [TDVisualApp] {
        store.apps.map { app in
            let label = app.label ?? app.packageName
            return TDVisualApp(
                name: label,
                packageName: app.packageName,
                symbol: Self.symbol(for: label),
                color: Self.color(for: app.packageName)
            )
        }
    }

    /// Önizleme görünümü — canlı scrcpy akışı veya hazır görsel.
    var screenContent: AnyView? {
        guard store.currentPreviewClient != nil else { return nil }
        return AnyView(VideoSurface())
    }

    // MARK: - Eylemler

    func makeActions() -> TDVisualActions {
        TDVisualActions(
            scan: { [weak self] in
                self?.store.refresh(clearError: true)
            },
            connect: { [weak self] device in
                self?.store.connect(to: device.address)
            },
            connectAddress: { [weak self] address in
                let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    self?.store.lastError = "Önce bir IP:port girin"
                    return
                }
                self?.store.connect(to: trimmed)
            },
            selectDevice: { [weak self] device in
                self?.store.selectedDeviceID = device.id
            },
            navigation: { [weak self] command in
                self?.handleNavigation(command)
            },
            openApp: { [weak self] app in
                guard let self else { return }
                if let match = self.store.apps.first(where: { $0.packageName == app.packageName }) {
                    self.store.launch(match)
                } else {
                    self.store.lastError = "Uygulama bulunamadı: \(app.packageName)"
                }
            },
            command: { [weak self] command in
                self?.handleCommand(command)
            }
        )
    }

    // MARK: - Gezinme

    private func handleNavigation(_ command: String) {
        switch command {
        case "back":       store.sendKey(.back)
        case "home":       store.sendKey(.home)
        case "menu":       store.sendKey(.menu)
        case "up":         store.sendKey(.dpadUp)
        case "ok":         store.sendKey(.dpadCenter)
        case "down":       store.sendKey(.dpadDown)
        case "left":       store.sendKey(.dpadLeft)
        case "right":      store.sendKey(.dpadRight)
        case "power":      store.sendKey(.power)
        case "search":     store.sendKey(.search)
        case "settings":   store.sendKey(.settings)
        case "info":       store.sendKey(.info)
        default:
            store.lastError = "Bu düğme henüz geliştirilmedi: \(command)"
        }
    }

    // MARK: - Genel komutlar

    private func handleCommand(_ command: String) {
        switch command {
        case "refresh":      store.refresh(clearError: true)
        case "screenshot":   store.screenshot()
        case "toggleScreen": store.wakeAndUnlock()
        case "wake":         store.wakeAndUnlock()
        case "fullscreen":   store.openScrcpy()
        case "display":      store.wakeAndUnlock()
        case "reboot":
            store.lastError = "'Cihazı Yeniden Başlat' henüz geliştirilmedi"
        case "deviceInfo":
            store.lastError = "'Cihaz Bilgileri' henüz geliştirilmedi"
        case "installApk", "fileTransfer":
            presentFilePicker(kind: command == "installApk" ? .apk : .anyFile)
        case "settings", "more":
            store.lastError = "Bu düğme henüz geliştirilmedi"
        default:
            if command.hasPrefix("type:") {
                store.sendText(String(command.dropFirst("type:".count)))
            } else if command.hasPrefix("sidebar:") {
                sidebarSection = String(command.dropFirst("sidebar:".count))
            } else {
                store.lastError = "Bu düğme henüz geliştirilmedi: \(command)"
            }
        }
    }

    // MARK: - Dosya seçici

    enum PickerKind { case apk, anyFile }

    private func presentFilePicker(kind: PickerKind) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        switch kind {
        case .apk:
            panel.title = "APK Seç ve Kur"
            panel.allowedContentTypes = [.init(filenameExtension: "apk")].compactMap { $0 }
        case .anyFile:
            panel.title = "Cihaza Aktarılacak Dosyaları Seç"
        }
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.store.handleDroppedFiles(panel.urls)
        }
    }

    // MARK: - Simge ve renk eşlemesi

    /// Uygulama simgesi için SF Symbol seçimi.
    static func symbol(for label: String) -> String {
        let lower = label.lowercased()
        if lower.contains("chrome") || lower.contains("tarayıcı") { return "globe" }
        if lower.contains("camera") || lower.contains("kamera") { return "camera.fill" }
        if lower.contains("youtube") || lower.contains("video") { return "play.rectangle.fill" }
        if lower.contains("mail") || lower.contains("gmail") { return "envelope.fill" }
        if lower.contains("setting") || lower.contains("ayar") { return "gearshape.fill" }
        if lower.contains("store") || lower.contains("mağaza") { return "bag.fill" }
        if lower.contains("photo") || lower.contains("foto") { return "photo.fill" }
        if lower.contains("map") || lower.contains("harita") { return "map.fill" }
        if lower.contains("music") || lower.contains("müzik") { return "music.note" }
        return "app.fill"
    }

    /// Paket adına göre tutarlı renk.
    static func color(for packageName: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .red, .purple, .teal, .pink, .indigo]
        let hash = abs(packageName.hashValue)
        return palette[hash % palette.count]
    }
}
