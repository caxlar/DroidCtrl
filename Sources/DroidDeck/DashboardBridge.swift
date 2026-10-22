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
//  GÜVENLİK: `TDVisualActions` geri çağrıları yalıtımsız (non-isolated)
//  kapanışlardır. SwiftUI bunları ana iş parçacığında çağırır ama bu garanti
//  DEĞİL; `@MainActor` metodu doğrudan çağırmak çalışma zamanı çökmesine yol
//  açabilir. Bu yüzden tüm girişler `onMain` üzerinden geçer.
//

import SwiftUI
import AppKit

@MainActor
final class DashboardBridge: ObservableObject {
    /// Gerçek `DeviceStore`.
    var store: DeviceStore

    /// Sol kenar çubuğu seçimi ("Cihazlar" / "Ayarlar" / "Hakkında").
    @Published var sidebarSection = "Cihazlar"
    /// Son otomatik yükleme yapılan cihaz — tekrar tekrar yüklememek için.
    private var autoLoadedForDevice: String?
    /// Son otomatik önizleme başlatılan cihaz.
    private var autoPreviewForDevice: String?

    init(store: DeviceStore) {
        self.store = store
    }

    /// Gerçek store'u bağla. `DashboardHost.onAppear` çağırır.
    func bind(to newStore: DeviceStore) {
        store = newStore
        objectWillChange.send()
    }

    // MARK: - Otomatik yükleme

    /// Seçili cihaz değiştiğinde: uygulamaları OTOMATİK yükler.
    ///
    /// ÖNİZLEME OTOMATİK BAŞLATILMAZ. Sürekli açık encoder cihazda pil ve
    /// ısınma yükü yaratır; kullanıcı isterse açar, işi bitince kapatır.
    func deviceSelectionChanged() {
        objectWillChange.send()

        guard let device = store.selectedDevice, device.state == .ready else { return }

        if autoLoadedForDevice != device.serial {
            autoLoadedForDevice = device.serial
            store.loadApps()
        }

        // Pil anında gelsin — telemetry beklemek yerine doğrudan çek.
        store.fetchBattery()
    }

    /// Önizlemeyi aç/kapat. Kullanıcı çağırdığında.
    func togglePreview() {
        if store.previewActive {
            store.stopPreview()
            autoPreviewForDevice = nil
        } else {
            store.startPreview()
            if let device = store.selectedDevice { autoPreviewForDevice = device.serial }
        }
        objectWillChange.send()
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

    /// Ekran alanı — kullanıcı isteğiyle:
    /// - Önizleme KAPALIYSA siyah zemin + ortada büyük ▶ düğmesi (tıklayınca açılır)
    /// - Önizleme AÇIKSA canlı scrcpy akışı
    ///
    /// Hazır görsel GÖSTERİLMEZ.
    var screenContent: AnyView? {
        if store.currentPreviewClient != nil {
            return AnyView(VideoSurface())
        }
        return AnyView(PreviewPlaceholder { [weak self] in
            self?.togglePreview()
        })
    }

    // MARK: - Eylemler

    func makeActions() -> TDVisualActions {
        TDVisualActions(
            scan: { [weak self] in self?.onMain { $0.store.refresh(clearError: true) } },
            connect: { [weak self] device in
                self?.onMain { $0.store.connect(to: device.address) }
            },
            connectAddress: { [weak self] address in
                self?.onMain { bridge in
                    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        bridge.store.lastError = "Önce bir IP:port girin"
                        return
                    }
                    bridge.store.connect(to: trimmed)
                }
            },
            selectDevice: { [weak self] device in
                self?.onMain { $0.store.selectedDeviceID = device.id }
            },
            navigation: { [weak self] command in
                self?.onMain { $0.handleNavigation(command) }
            },
            openApp: { [weak self] app in
                self?.onMain { bridge in
                    if let match = bridge.store.apps.first(where: { $0.packageName == app.packageName }) {
                        bridge.store.launch(match)
                    } else {
                        bridge.store.lastError = "Uygulama bulunamadı: \(app.packageName)"
                    }
                }
            },
            command: { [weak self] command in
                self?.onMain { $0.handleCommand(command) }
            }
        )
    }

    /// Yalıtımsız geri çağrıları güvenli biçimde ana iş parçacığına taşır.
    ///
    /// Zaten ana iş parçacığındaysak EŞZAMANLI çalışır (düğme gecikmesi yok);
    /// değilse ana kuyruğa alınır. Bu, `@MainActor` metoda yalıtımsız erişimden
    /// doğan çalışma zamanı çökmesini engeller.
    private func onMain(_ work: @escaping (DashboardBridge) -> Void) {
        if Thread.isMainThread {
            work(self)
        } else {
            DispatchQueue.main.async { [weak self] in
                if let self { work(self) }
            }
        }
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
        case "toggleScreen": store.toggleDisplayPower()
        case "wake":         store.wakeAndUnlock()
        case "fullscreen":   store.openScrcpy()
        case "display":      store.toggleDisplayPower()
        case "enter":        store.sendRawKey(66)   // KEYCODE_ENTER
        case "delete":       store.sendRawKey(67)   // KEYCODE_DEL
        case "deviceInfo":   store.showDeviceInfo()
        case "openSettings": openDeviceSettings()
        case "about":
            store.statusMessage = """
            DroidDeck — Android Cihaz Kontrol Merkezi
            adb + gömülü scrcpy istemcisi
            Ağa açık değil: yalnızca yerel ağ üzerinden çalışır.
            """
        case "togglePreview":
            togglePreview()
        case "disconnect":
            if let device = store.selectedDevice {
                store.disconnect(device)
                autoLoadedForDevice = nil
                autoPreviewForDevice = nil
            }
        case "loadApps":
            store.loadApps()
        case "reboot":
            store.rebootDevice()
        case "resetLabels":
            store.resetLabels()
        case "restartADB":
            store.restartADBServer()
        case "installApk", "fileTransfer":
            presentFilePicker(kind: command == "installApk" ? .apk : .anyFile)
        case "settings":
            // Üst başlıktaki "Ayarlar" — cihazın Ayarlar uygulamasını açar.
            openDeviceSettings()
        case "more":
            handleCommand("about")
        default:
            if command.hasPrefix("type:") {
                store.sendText(String(command.dropFirst("type:".count)))
            } else if command.hasPrefix("media:") {
                let raw = String(command.dropFirst("media:".count))
                if let action = MediaAction(rawValue: raw) {
                    store.sendMedia(action)
                } else {
                    store.lastError = "Bilinmeyen medya komutu: \(raw)"
                }
            } else if command.hasPrefix("sendURL:") {
                store.sendURL(String(command.dropFirst("sendURL:".count)))
            } else if command.hasPrefix("forceStop:") {
                let package = String(command.dropFirst("forceStop:".count))
                if let app = store.apps.first(where: { $0.packageName == package }) {
                    store.forceStop(app)
                } else {
                    store.lastError = "Uygulama bulunamadı: \(package)"
                }
            } else if command.hasPrefix("quality:") {
                let name = String(command.dropFirst("quality:".count))
                switch name {
                case "Düşük":        store.previewQuality = .low
                case "Yüksek (TV)":  store.previewQuality = .high
                default:             store.previewQuality = .balanced
                }
                // Kalite değişince aktif oturum yeniden kurulmalı.
                if store.previewActive {
                    store.stopPreview()
                    store.startPreview()
                }
            } else if command.hasPrefix("sidebar:") {
                sidebarSection = String(command.dropFirst("sidebar:".count))
            } else {
                store.lastError = "Bu düğme henüz geliştirilmedi: \(command)"
            }
        }
        objectWillChange.send()
    }

    // MARK: - Dosya seçici

    /// Cihazın Ayarlar uygulamasını açar.
    private func openDeviceSettings() {
        guard let adb = store.adb, let device = store.selectedDevice else {
            store.lastError = "Önce bir cihaz seçin"
            return
        }
        let serial = device.serial

        // Önce listeden bulmayı dene.
        if let app = store.apps.first(where: { $0.packageName == "com.android.settings" }) {
            store.launch(app)
            return
        }

        // Listede yoksa doğrudan intent ile aç.
        store.statusMessage = "Ayarlar uygulaması açılıyor…"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = adb.shell(serial, [
                "am", "start", "-n", "com.android.settings/.Settings"
            ], timeout: 10)
            DispatchQueue.main.async {
                if !r.succeeded {
                    self.store.lastError = "Ayarlar açılamadı: \(r.combined)"
                }
            }
        }
    }

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
            guard response == .OK else { return }
            self?.onMain { $0.store.handleDroppedFiles(panel.urls) }
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
