import Foundation
import Combine

/// Tüm uygulama durumu ve ADB işlemlerini yöneten tek kaynak.
@MainActor
final class DeviceStore: ObservableObject {

    // MARK: - Yayınlanan durum

    @Published var devices: [AndroidDevice] = []
    @Published var mdnsServices: [MDNSService] = []

    @Published var isScanning = false
    @Published var statusMessage = "Başlatılıyor…"
    @Published var lastError: String?

    @Published var adbPath: String?
    @Published var scrcpyPath: String?

    @Published var selectedDeviceID: String?

    @Published var apps: [AndroidApp] = []
    @Published var isLoadingApps = false
    @Published var appFilter = ""
    @Published var labelStatus = ""

    /// Yayının gerçekten **şu an seçili** cihaza bağlı olup olmadığı.
    /// Yanlış cihaza tuş/metin göndermemek için kullanılır.
    private var isPreviewBoundToSelection: Bool {
        previewActive && previewClient != nil && previewSerial == selectedDeviceID
    }

    // MARK: - Ekran önizleme (yerleşik)
    @Published var previewActive = false
    @Published var previewStatus = ""
    @Published var videoSize: CGSize = .zero
    /// Cihazın anlık sıcaklığı (°C) — termal koruma için.
    @Published var deviceTemperature: Int?
    /// Cihaz pil seviyesi (%).
    @Published var batteryLevel: Int?
    /// Küçük önizlemenin cihaza bindireceği yük.
    @Published var previewQuality: PreviewQuality = .balanced

    weak var videoSink: SurfaceNSView?
    private var previewClient: ScrcpyClient?
    /// Yayının hangi cihaza bağlı olduğu. Cihaz değişince oturum kapatılmalı.
    private var previewSerial: String?
    private var thermalTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    @Published var manualEndpoint = ""

    // MARK: - Eşleştirme sihirbazı
    @Published var showPairingSheet = false
    @Published var pairingTargetIP = ""
    @Published var pairingStatus = ""
    @Published var pairingCode = ""
    @Published var pairingService: MDNSService?
    @Published var isPairingBusy = false
    @Published var pairingFinished = false
    private var pairingTimer: Timer?

    // MARK: - Hesaplananlar

    var adb: ADBService? {
        guard let adbPath else { return nil }
        return ADBService(adbPath: adbPath)
    }

    var selectedDevice: AndroidDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var filteredApps: [AndroidApp] {
        let query = appFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.packageName.lowercased().contains(query) ||
            $0.displayName.lowercased().contains(query)
        }
    }

    /// mDNS'te görünüp henüz `adb devices` listesinde olmayan cihazlar.
    var undiscoveredMDNS: [MDNSService] {
        mdnsServices.filter { service in
            !devices.contains { $0.serial == service.endpoint || $0.serial == service.instance }
        }
    }

    // MARK: - Başlatma

    init() {
        adbPath = ADBService.locateADB()
        scrcpyPath = ADBService.locateScrcpy()
        if adbPath == nil {
            lastError = "adb bulunamadı. Kurulum: brew install --cask android-platform-tools"
            statusMessage = "adb eksik"
        }

        // Seçili cihaz değiştiğinde önceki cihaza ait TÜM durumu temizle.
        // Yalnızca yayını kapatmak yetmez: uygulama listesi eski cihazda kalır
        // ve tıklanınca yanlış cihaza komut gider.
        $selectedDeviceID
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.resetDeviceScopedState()
            }
            .store(in: &cancellables)
    }

    /// Seçili cihaz değiştiğinde önceki cihaza ait durumu sıfırlar.
    private func resetDeviceScopedState() {
        stopPreview()
        apps = []
        labelStatus = ""
        appFilter = ""
        videoSize = .zero
        unlockStatus = ""
        transferStatus = ""
        syncTelemetry()
    }

    // MARK: - Keşif

    func refresh(selectEndpoint: String? = nil, clearError: Bool = true) {
        guard let adb else {
            lastError = "adb bulunamadı. Kurulum: brew install --cask android-platform-tools"
            return
        }

        isScanning = true
        statusMessage = "Cihazlar taranıyor…"
        if clearError { lastError = nil }

        DispatchQueue.global(qos: .userInitiated).async {
            let foundDevices = adb.listDevices()
            let foundServices = adb.listMDNSServices()

            DispatchQueue.main.async {
                self.devices = foundDevices
                self.mdnsServices = foundServices
                self.isScanning = false

                if let selected = self.selectedDeviceID,
                   !foundDevices.contains(where: { $0.id == selected }) {
                    self.selectedDeviceID = nil
                    self.apps = []
                    // Seçim kalktıysa yayın açık kalmasın — cihazda yük bırakma.
                    self.stopPreview()
                }

                // Yeni bağlanan cihazı otomatik seç.
                if let target = selectEndpoint {
                    let host = target.split(separator: ":").first.map(String.init) ?? target
                    // Sınır kontrollü eşleşme: "192.168.1.4", "192.168.1.40" ile
                    // karışmasın diye ya birebir ya da "host:" önekiyle eşleşir.
                    if let match = foundDevices.first(where: { $0.serial == target })
                        ?? foundDevices.first(where: { $0.serial == host })
                        ?? foundDevices.first(where: { $0.serial.hasPrefix(host + ":") }) {
                        self.selectedDeviceID = match.id
                    }
                }

                let controllable = foundDevices.filter { $0.state.isControllable }.count
                if foundDevices.isEmpty && foundServices.isEmpty {
                    self.statusMessage = "Ağda cihaz bulunamadı"
                } else {
                    self.statusMessage = "\(controllable) cihaz hazır · \(foundDevices.count) kayıt"
                }
            }
        }
    }

    func connect(to endpoint: String) {
        guard let adb else { return }
        let target = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }

        statusMessage = "Bağlanılıyor: \(target)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = adb.connect(to: target)
            DispatchQueue.main.async {
                if result.succeeded {
                    self.statusMessage = "Bağlandı: \(target)"
                    self.refresh(selectEndpoint: target)
                } else {
                    self.lastError = "Bağlanamadı: \(result.combined)"
                    // Hatayı SİLME — kullanıcı neden bağlanamadığını görmeli.
                    self.refresh(clearError: false)
                }
            }
        }
    }

    func connect(_ service: MDNSService) {
        guard let adb else { return }

        statusMessage = "Bağlanılıyor: \(service.endpoint)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = adb.connect(to: service.endpoint)
            DispatchQueue.main.async {
                if result.succeeded {
                    self.statusMessage = "Bağlandı: \(service.endpoint)"
                    self.refresh(selectEndpoint: service.endpoint)
                } else {
                    // Güvenli bağlantı başarısızsa en olası sebep eksik eşleşmedir.
                    if service.isSecureConnect {
                        self.lastError = nil
                        self.beginPairing(
                            ip: service.host,
                            reason: "Bağlanamadı — bu cihaz bu bilgisayarla eşleştirilmemiş olabilir. Aşağıdaki adımları izleyin.")
                    } else {
                        self.lastError = "Bağlanamadı: \(result.combined)"
                    }
                }
            }
        }
    }

    func disconnect(_ device: AndroidDevice) {
        guard let adb else { return }

        // Bağlantısı kesilen cihazın yayını ve seçimi de kapansın.
        if previewSerial == device.serial || selectedDeviceID == device.id {
            stopPreview()
        }
        if selectedDeviceID == device.id {
            selectedDeviceID = nil
        }

        DispatchQueue.global(qos: .userInitiated).async {
            _ = adb.disconnect(device.serial)
            DispatchQueue.main.async { self.refresh() }
        }
    }

    func restartADBServer() {
        guard let adb else { return }
        statusMessage = "ADB sunucusu yeniden başlatılıyor…"
        DispatchQueue.global(qos: .userInitiated).async {
            _ = adb.restartServer()
            DispatchQueue.main.async { self.refresh() }
        }
    }

    // MARK: - Eşleştirme sihirbazı

    /// Sihirbazı açar. `ip` boşsa genel amaçlı açılır.
    func beginPairing(ip: String, reason: String? = nil) {
        pairingTargetIP = ip
        pairingCode = ""
        pairingService = nil
        pairingFinished = false
        isPairingBusy = false
        pairingStatus = reason ?? "Telefonda eşleştirme penceresini açın (aşağıdaki adımlar)."
        showPairingSheet = true
        startPairingWatch()
    }

    func cancelPairing() {
        stopPairingWatch()
        showPairingSheet = false
        pairingService = nil
        pairingCode = ""
        pairingStatus = ""
        pairingTargetIP = ""
    }

    /// Sihirbaz herhangi bir yolla kapandığında çağrılır (Kapat/İptal dışında
    /// yollar da olabilir). Zamanlayıcı mutlaka durdurulmalı — aksi halde
    /// 2 saniyede bir ADB taraması süresiz devam eder.
    func pairingSheetDidClose() {
        stopPairingWatch()
        pairingService = nil
        pairingCode = ""
        pairingTargetIP = ""
    }

    private func startPairingWatch() {
        stopPairingWatch()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.pollPairingService() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        pairingTimer = timer
        pollPairingService()
    }

    private func stopPairingWatch() {
        pairingTimer?.invalidate()
        pairingTimer = nil
    }

    /// `_adb-tls-pairing._tcp` servisini arar — bu yalnızca cihazda eşleştirme
    /// penceresi açıkken yayınlanır, dolayısıyla "pencere açık mı"nın kanıtıdır.
    private func pollPairingService() {
        guard let adb else { return }
        let targetIP = pairingTargetIP

        DispatchQueue.global(qos: .userInitiated).async {
            let services = adb.listMDNSServices()
            let pairingServices = services.filter { $0.isPairingService }
            // Hedef IP ile eşleşeni tercih et; amaçlanan IP boşsa ya da
            // bulunamazsa herhangi bir eşleştirme servisini kabul et.
            let found = pairingServices.first { $0.host == targetIP } ?? pairingServices.first

            DispatchQueue.main.async {
                if let found {
                    if self.pairingService?.endpoint != found.endpoint {
                        self.pairingService = found
                        self.pairingStatus = "Eşleştirme penceresi bulundu (\(found.endpoint)). Telefondaki 6 haneli kodu aşağıya yazın."
                    }
                } else if self.pairingService == nil, !self.pairingFinished {
                    self.pairingStatus = "Telefonda eşleştirme penceresi bekleniyor… (sihirbazdaki 3. adım)"
                }
            }
        }
    }

    /// Kullanıcının girdiği kodla eşleşmeyi yapar, sonra otomatik bağlanır.
    func submitPairingCode() {
        guard let adb else { return }
        guard let service = pairingService else {
            pairingStatus = "Önce telefonda eşleştirme penceresini açın — kod ekranda görünmeli."
            return
        }
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count >= 4 else {
            pairingStatus = "Kod en az 4 haneli olmalı."
            return
        }

        isPairingBusy = true
        pairingStatus = "Eşleştiriliyor…"
        let endpoint = service.endpoint
        let host = service.host

        DispatchQueue.global(qos: .userInitiated).async {
            let result = adb.pair(endpoint: endpoint, code: code)

            DispatchQueue.main.async {
                self.pairingCode = ""          // kodu asla saklama
                let output = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
                let ok = result.exitCode == 0 && !output.lowercased().contains("fail")

                guard ok else {
                    self.isPairingBusy = false
                    self.pairingStatus = "Eşleşme başarısız. \(output.isEmpty ? "Kod yanlış olabilir; telefonda pencereyi kapatıp yeniden açın." : output)"
                    return
                }

                self.pairingStatus = "Eşleşme başarılı. Bağlanılıyor…"

                // Eşleşmeden sonra bağlantı portunu bulup otomatik bağlan.
                DispatchQueue.global(qos: .userInitiated).async {
                    let services = adb.listMDNSServices()
                    let connectService = services.first { $0.isSecureConnect && $0.host == host }
                    let target = connectService?.endpoint ?? "\(host):5555"
                    let connectResult = adb.connect(to: target)

                    DispatchQueue.main.async {
                        self.isPairingBusy = false
                        self.pairingFinished = true
                        self.stopPairingWatch()
                        if connectResult.succeeded {
                            self.pairingStatus = "Bağlandı: \(target). Cihaz listede hazır."
                        } else {
                            self.pairingStatus = "Eşleşme tamam ama bağlantı kurulamadı. Soldaki 'Bağlan' ile deneyin."
                        }
                        self.refresh(selectEndpoint: target)
                    }
                }
            }
        }
    }

    // MARK: - Uygulamalar

    /// Ana ekrandaki uygulamaları listeler ve gerçek adları APK'dan çözer.
    /// Adlar çözüldükçe arayüz adım adım güncellenir; sonuç diskte önbelleklenir.
    func loadApps() {
        guard let adb, let device = selectedDevice, device.state.isControllable else { return }
        lastError = nil   // yeni eylem başlıyor

        isLoadingApps = true
        labelStatus = "Uygulamalar listeleniyor…"
        let serial = device.serial

        DispatchQueue.global(qos: .userInitiated).async {
            let found = adb.listLaunchableApps(serial)
            let locale = LabelCLI.deviceLocale(adb: adb, serial: serial)
            let cache = LabelCache.forSerial(serial)

            // 1) Önbellekteki adlar anında uygulanır.
            var resolved = found.map { app -> AndroidApp in
                var copy = app
                copy.label = cache.label(for: app.packageName)
                return copy
            }
            DispatchQueue.main.async {
                // Kullanıcı bu sırada başka cihaza geçtiyse sonucu yazma.
                guard self.selectedDevice?.serial == serial else { return }
                self.apps = resolved
                self.labelStatus = "Gerçek adlar çözülüyor…"
            }

            // 2) Eksik adlar APK'dan çözülür (en fazla 4 eşzamanlı işlem).
            let lock = NSLock()
            let group = DispatchGroup()
            let semaphore = DispatchSemaphore(value: 4)
            let worker = DispatchQueue(label: "droiddeck.labels", attributes: .concurrent)

            // İş listesini ÖNCE, değişmez biçimde çıkar. Döngü sürerken
            // worker'lar `resolved`'a yazmaya başladığı için diziyi döngü
            // içinde okumak veri yarışıydı.
            let pending: [(index: Int, packageName: String)] = resolved.indices
                .filter { resolved[$0].label == nil }
                .map { ($0, resolved[$0].packageName) }

            for (index, packageName) in pending {
                group.enter()
                worker.async {
                    semaphore.wait()
                    let result = LabelCLI.label(for: packageName, adb: adb, serial: serial, locale: locale)
                    semaphore.signal()

                    if let label = result.label {
                        cache.store(label, for: packageName)
                        lock.lock()
                        if index < resolved.count {
                            resolved[index].label = label
                        }
                        let snapshot = resolved
                        lock.unlock()

                        DispatchQueue.main.async {
                            guard self.selectedDevice?.serial == serial else { return }
                            self.apps = snapshot
                            let done = snapshot.filter { $0.isRealLabel }.count
                            self.labelStatus = "Gerçek adlar: \(done)/\(snapshot.count)"
                        }
                    }
                    group.leave()
                }
            }

            group.wait()
            cache.save()

            DispatchQueue.main.async {
                guard self.selectedDevice?.serial == serial else { return }
                self.apps = resolved
                self.isLoadingApps = false
                let done = resolved.filter { $0.isRealLabel }.count
                self.labelStatus = "Gerçek ad: \(done)/\(resolved.count)"
            }
        }
    }

    func launch(_ app: AndroidApp) {
        guard let adb, let device = selectedDevice else { return }
        lastError = nil   // yeni eylem başlıyor
        let serial = device.serial

        DispatchQueue.global(qos: .userInitiated).async {
            let result = adb.launchApp(serial,
                                       packageName: app.packageName,
                                       componentName: app.componentName)
            DispatchQueue.main.async {
                if !result.succeeded {
                    self.lastError = "Uygulama açılamadı: \(result.combined)"
                }
            }
        }
    }

    func forceStop(_ app: AndroidApp) {
        guard let adb, let device = selectedDevice else { return }
        let serial = device.serial

        DispatchQueue.global(qos: .userInitiated).async {
            _ = adb.forceStop(serial, packageName: app.packageName)
        }
    }

    /// Uygulama etiketi önbelleğini siler ve yeniden çözümletir.
    /// Uygulama güncellendiğinde eski adlar kalmasın diye.
    func resetLabels() {
        guard let device = selectedDevice else { return }
        LabelCache.forSerial(device.serial).clear()
        apps = []
        labelStatus = "Etiketler sıfırlandı, yeniden çözülüyor…"
        loadApps()
    }

    // MARK: - Telemetri / durum panosu
    //
    // Cihazın RAM/CPU/pil/sıcaklık/depolama/ağ durumu. Termal korumadan farklı:
    // bu YALNIZCA okur ve gösterir, hiçbir şeye müdahale etmez. Aralıklı okuma
    // bilinçli olarak 8 sn — cihaza yük bindirmemek için (özellikle RAM'i
    // zaten sıkışık TV'de).

    @Published var telemetry = DeviceTelemetry.empty
    @Published var transferStatus = ""

    private var telemetryTimer: Timer?

    /// Telemetri aralığı (saniye). Cihaza yük bindirmemek için bilinçli olarak
    /// seyrek — her tur yalnızca 3 adb süreci başlatır.
    private static let telemetryInterval: TimeInterval = 12

    /// Seçili cihaza göre telemetriyi başlatır/durdurur.
    ///
    /// NEDEN `isControllable` DEĞİL: seçici devreye girdiğinde cihaz durumu
    /// henüz "controllable" olmayabilir. Yalnızca o an kontrol edilebilir
    /// cihazlarda başlatmak, telemetrinin hiç başlamamasına yol açıyordu
    /// (arayüzde etiketler görünüyor, değerler boş kalıyordu). Zamanlayıcı
    /// seçili cihaz varken dönsün; `refreshTelemetry()` kontrol edilebilir
    /// değilse zaten sessizce atlar.
    func syncTelemetry() {
        if selectedDevice != nil {
            startTelemetry()
        } else {
            stopTelemetry()
            telemetry = .empty
        }
    }

    private func startTelemetry() {
        guard telemetryTimer == nil else { return }
        // Timer ana run loop'ta çalışır; bunu derleyiciye söylüyoruz.
        let timer = Timer.scheduledTimer(withTimeInterval: Self.telemetryInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshTelemetry()
            }
        }
        timer.tolerance = 2
        telemetryTimer = timer
        refreshTelemetry()
    }

    func stopTelemetry() {
        telemetryTimer?.invalidate()
        telemetryTimer = nil
    }

    func refreshTelemetry() {
        guard let adb, let device = selectedDevice, device.state.isControllable else { return }
        let serial = device.serial
        DispatchQueue.global(qos: .utility).async {
            let t = adb.telemetry(serial: serial)
            DispatchQueue.main.async {
                guard self.selectedDevice?.serial == serial else { return }
                self.telemetry = t
            }
        }
    }

    // MARK: - Ekranı uyandır + kilidi aç

    /// Ekran kapalıyken/kilitliyken tek tuşla açar.
    ///
    /// Senin tarif ettiğin durum içindir: ekran kapanmış, açmak için önce
    /// uyandırıp sonra yukarı kaydırman gerekiyor. PIN/desen/şifre kilitliyse
    /// Android zaten açılmasına izin vermez — bu bir sınır, hata değil.
    @Published var unlockStatus = ""

    func wakeAndUnlock() {
        guard let adb, let device = selectedDevice else {
            unlockStatus = "Önce bir cihaz seçin."
            return
        }
        let serial = device.serial
        unlockStatus = "Gönderiliyor…"
        DispatchQueue.global(qos: .userInitiated).async {
            let steps = adb.wakeAndUnlock(serial: serial)
            DispatchQueue.main.async {
                guard self.selectedDevice?.serial == serial else { return }
                self.unlockStatus = steps.joined(separator: "\n")
            }
        }
    }

    // MARK: - URL / link gönderme

    /// Mac'teki bağlantıyı cihazda açar.
    func sendURL(_ raw: String) {
        guard let adb, let device = selectedDevice, device.state.isControllable else {
            transferStatus = "Önce bir cihaz seçin."
            return
        }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Protokol yoksa https varsay — kullanıcılar genelde yalnızca alan adı yazar.
        if !text.contains("://") { text = "https://" + text }

        let serial = device.serial
        transferStatus = "Açılıyor: \(text)"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = adb.sendURL(text, serial: serial)
            DispatchQueue.main.async {
                guard self.selectedDevice?.serial == serial else { return }
                self.transferStatus = r.succeeded
                    ? "✓ Cihazda açıldı: \(text)"
                    : "✗ Açılırken hata: \(r.combined)"
            }
        }
    }

    // MARK: - Dosya sürükle-bırak

    /// Pencereye bırakılan dosyaları cihaza gönderir.
    /// `.apk` → kurulur; diğerleri `/sdcard/Download/` altına itilip medya
    /// tarayıcıya bildirilir (galeride görünmesi için).
    func handleDroppedFiles(_ urls: [URL]) {
        guard let adb, let device = selectedDevice, device.state.isControllable else {
            transferStatus = "Önce bir cihaz seçin."
            return
        }
        guard !urls.isEmpty else { return }

        let serial = device.serial
        transferStatus = "Gönderiliyor (\(urls.count) dosya)…"
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                let name = url.lastPathComponent
                if url.pathExtension.lowercased() == "apk" {
                    let r = adb.installAPK(localURL: url, serial: serial)
                    lines.append(r.succeeded
                                 ? "✓ Kuruldu: \(name)"
                                 : "✗ Kurulum başarısız: \(name) — \(r.combined)")
                } else {
                    let r = adb.pushFile(localURL: url, serial: serial)
                    if r.succeeded {
                        _ = adb.scanMedia(remotePath: "/sdcard/Download/\(name)", serial: serial)
                        lines.append("✓ Gönderildi: \(name)")
                    } else {
                        lines.append("✗ Gönderilemedi: \(name) — \(r.combined)")
                    }
                }
            }
            DispatchQueue.main.async {
                self.transferStatus = lines.joined(separator: "\n")
            }
        }
    }

    // MARK: - Ekran görüntüsü

    @Published var screenshotStatus = ""

    /// Ekran görüntüsü alır ve Masaüstü'ne PNG olarak kaydeder.
    func screenshot() {
        guard let adb, let device = selectedDevice, device.state.isControllable else {
            screenshotStatus = "Önce bir cihaz seçin."
            return
        }
        let serial = device.serial
        screenshotStatus = "Alınıyor…"
        DispatchQueue.global(qos: .userInitiated).async {
            let remote = "/sdcard/droiddeck_shot.png"
            _ = adb.shell(serial, ["screencap", "-p", remote], timeout: 20)

            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            let name = "DroidDeck-\(f.string(from: Date())).png"
            let dest = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop")
                .appendingPathComponent(name)

            let r = adb.adb(["-s", serial, "pull", remote, dest.path], timeout: 30)
            _ = adb.shell(serial, ["rm", "-f", remote], timeout: 10)

            DispatchQueue.main.async {
                self.screenshotStatus = r.succeeded
                    ? "✓ Kaydedildi: \(dest.lastPathComponent)"
                    : "✗ Ekran görüntüsü alınamadı: \(r.combined)"
            }
        }
    }

    // MARK: - Kontrol

    func sendKey(_ keyCode: KeyCode) {
        if let client = previewClient, isPreviewBoundToSelection {
            client.sendKey(action: 0, keycode: UInt32(keyCode.rawValue))
            client.sendKey(action: 1, keycode: UInt32(keyCode.rawValue))
            return
        }
        send { adb, serial in
            _ = adb.keyevent(serial, keyCode)
        }
    }

    func sendRawKey(_ code: Int) {
        if let client = previewClient, isPreviewBoundToSelection {
            client.sendKey(action: 0, keycode: UInt32(code))
            client.sendKey(action: 1, keycode: UInt32(code))
            return
        }
        send { adb, serial in
            _ = adb.keyevent(serial, rawCode: code)
        }
    }

    func sendMedia(_ action: MediaAction) {
        send { adb, serial in
            _ = adb.media(serial, action)
        }
    }

    func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let client = previewClient, isPreviewBoundToSelection {
            client.sendText(trimmed)
            return
        }
        send { adb, serial in
            _ = adb.typeText(serial, trimmed)
        }
    }

    func sendTap(x: Int, y: Int) {
        send { adb, serial in
            _ = adb.tap(serial, x: x, y: y)
        }
    }

    private func send(_ work: @escaping (ADBService, String) -> Void) {
        guard let adb else { return }
        lastError = nil   // yeni eylem başlıyor; önceki hata ekranda kalmasın
        guard let device = selectedDevice else {
            lastError = "Önce bir cihaz seçin."
            return
        }
        guard device.state.isControllable else {
            lastError = "\(device.displayName) kontrol edilebilir durumda değil (\(device.state.label))."
            return
        }

        let serial = device.serial
        DispatchQueue.global(qos: .userInitiated).async {
            work(adb, serial)
        }
    }

    // MARK: - Ekran

    /// Küçük önizlemeyi başlatır (yerleşik scrcpy istemcisi).
    func startPreview() {
        guard let device = selectedDevice, device.state.isControllable else {
            lastError = "Önce kontrol edilebilir bir cihaz seçin."
            return
        }
        guard let adbPath else { return }
        lastError = nil   // yeni eylem başlıyor

        // Önceki oturum varsa (önceki cihazdan kalmış olabilir) mutlaka kapat.
        if previewClient != nil {
            stopPreview()
        }

        guard let serverPath = ADBService.locateScrcpyServer() else {
            lastError = "scrcpy-server bulunamadı. `brew install scrcpy` kurulu mu?"
            return
        }

        let serial = device.serial
        previewSerial = serial
        previewStatus = "Başlatılıyor…"
        previewActive = true

        let client = ScrcpyClient()
        previewClient = client

        // Geri çağrıları KENDİ client nesnesine bağla. Aksi halde eski oturumun
        // onStopped'u yeni oturumu silebilir: arayüz "Durduruldu" derken yayın
        // cihazda açık kalır ve encoder çalışmaya devam eder.
        client.onPixelBuffer = { [weak self] buffer, pts in
            // VideoToolbox iş parçacığından gelir; NSView erişimi ana iş parçacığı ister.
            DispatchQueue.main.async {
                self?.videoSink?.enqueue(imageBuffer: buffer, pts: pts)
            }
        }
        client.onVideoSize = { [weak self] size in
            DispatchQueue.main.async {
                guard self?.previewClient === client else { return }
                self?.videoSize = size
            }
        }
        client.onError = { [weak self] message in
            DispatchQueue.main.async {
                guard self?.previewClient === client else { return }
                // Hata termal yoklama tarafından ezilmemeli: lastError kalıcıdır.
                self?.lastError = message
                self?.previewStatus = "Hata: \(message)"
            }
        }
        client.onStopped = { [weak self] in
            DispatchQueue.main.async {
                guard self?.previewClient === client else { return }
                self?.previewActive = false
                self?.previewClient = nil
                self?.previewSerial = nil
                self?.previewStatus = "Durduruldu"
            }
        }

        client.start(adbPath: adbPath,
                     serial: serial,
                     serverLocalPath: serverPath,
                     maxSize: previewQuality.maxSize,
                     maxFPS: previewQuality.maxFPS,
                     bitRate: previewQuality.bitRate) {
            [weak self] ok, error in
            DispatchQueue.main.async {
                // Bu yanıt başka bir oturuma aitse güncel durumu ezmeyesin.
                guard self?.previewClient === client else { return }
                if ok {
                    self?.previewActive = true
                    self?.previewStatus = "Canlı"
                    self?.startThermalMonitor()
                } else {
                    self?.previewClient = nil
                    self?.previewSerial = nil
                    self?.previewActive = false
                    self?.previewStatus = error ?? "Başlatılamadı"
                    self?.lastError = error
                }
            }
        }
    }

    func stopPreview() {
        stopThermalMonitor()
        previewClient?.stop()
        previewClient = nil
        previewSerial = nil
        previewActive = false
        previewStatus = "Durduruldu"
        videoSink?.displayLayer.flushAndRemoveImage()
    }

    /// Uygulama kapanırken yayını keser — cihazda gereksiz encoder bırakmaz.
    func shutdownForTermination() {
        stopPreview()
    }

    // MARK: - Termal koruma

    private func startThermalMonitor() {
        stopThermalMonitor()
        guard let adb, let device = selectedDevice else { return }
        let serial = device.serial

        let timer = Timer(timeInterval: ThermalLimit.pollSeconds, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                let battery = adb.batteryInfo(serial: serial)
                DispatchQueue.main.async {
                    self?.handleThermal(battery)
                }
            }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        thermalTimer = timer

        // İlk okumayı hemen yap.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let battery = adb.batteryInfo(serial: serial)
            DispatchQueue.main.async {
                self?.handleThermal(battery)
            }
        }
    }

    private func stopThermalMonitor() {
        thermalTimer?.invalidate()
        thermalTimer = nil
    }

    private func handleThermal(_ battery: ADBService.BatteryInfo) {
        deviceTemperature = battery.temperatureC
        batteryLevel = battery.levelPercent

        guard previewActive, let temperature = battery.temperatureC else { return }

        if temperature >= ThermalLimit.stopCelsius {
            stopPreview()
            previewStatus = "Termal koruma: yayın durduruldu"
            lastError = "Cihaz \(temperature)°C'ye ulaştı. Güvenlik için yayın durduruldu."
        } else if temperature >= ThermalLimit.warnCelsius {
            previewStatus = "Canlı · \(temperature)°C (yüksek)"
        } else {
            previewStatus = "Canlı · \(temperature)°C"
        }
    }

    /// Önizleme alanındaki dokunma/tıklama. `action`: 0=bas, 1=kaldır, 2=taşı.
    func previewTouch(point: CGPoint, action: Int) {
        guard let client = previewClient, isPreviewBoundToSelection else { return }
        let size = videoSize == .zero ? CGSize(width: 1280, height: 720) : videoSize
        let pressed = action != 1
        client.sendTouch(action: UInt8(action),
                         x: Int(point.x), y: Int(point.y),
                         width: Int(size.width), height: Int(size.height),
                         pressure: pressed ? 1.0 : 0.0,
                         actionButton: pressed ? 1 : 0,
                         buttons: pressed ? 1 : 0)
    }

    func previewScroll(point: CGPoint, dx: CGFloat, dy: CGFloat) {
        guard let client = previewClient, isPreviewBoundToSelection else { return }
        let size = videoSize == .zero ? CGSize(width: 1280, height: 720) : videoSize
        client.sendScroll(x: Int(point.x), y: Int(point.y),
                          width: Int(size.width), height: Int(size.height),
                          hScroll: Float(dx), vScroll: Float(dy))
    }

    /// Tam ekran pencereyi (scrcpy'nin kendi penceresi) açar.
    func openScrcpy() {
        guard let adb else { return }
        lastError = nil   // yeni eylem başlıyor
        guard let device = selectedDevice else {
            lastError = "Önce bir cihaz seçin."
            return
        }
        guard device.state.isControllable else {
            lastError = "\(device.displayName) kontrol edilebilir durumda değil."
            return
        }

        let serial = device.serial
        let quality = previewQuality
        DispatchQueue.global(qos: .userInitiated).async {
            let result = adb.launchScrcpy(serial: serial,
                                          maxFPS: quality.maxFPS,
                                          bitRateMbps: max(1, quality.bitRate / 1_000_000))
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.statusMessage = "Ekran penceresi açıldı"
                case .failure(let error):
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func reloadToolPaths() {
        adbPath = ADBService.locateADB()
        scrcpyPath = ADBService.locateScrcpy()
        if adbPath == nil {
            lastError = "adb bulunamadı. Kurulum: brew install --cask android-platform-tools"
        } else {
            lastError = nil
            refresh()
        }
    }
}
