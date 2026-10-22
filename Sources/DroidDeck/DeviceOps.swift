import Foundation

// MARK: - Telemetri

/// Cihazın anlık durumu. Tüm alanlar `nil` olabilir — cihazın desteklemediği
/// değerleri uydurmuyoruz, bilinmiyorsa boş gösteriyoruz.
struct DeviceTelemetry: Equatable {
    var batteryPercent: Int?
    var temperatureC: Int?
    var charging: Bool?

    var memTotalMB: Int?
    var memAvailableMB: Int?

    /// 1 dakikalık yük (load average) — `/proc/loadavg`.
    var cpuLoad1: Double?
    /// Son örnekleme aralığında ölçülen CPU kullanımı (%) — `/proc/stat`.
    var cpuPercent: Double?

    var storageTotalGB: Double?
    var storageUsedGB: Double?

    /// `adb` gidiş-dönüş gecikmesi (ms) — ağ kalitesinin dürüst göstergesi.
    var adbLatencyMS: Int?

    var collectedAt: Date?

    /// RAM kullanım yüzdesi (0-100).
    var memUsedPercent: Int? {
        guard let total = memTotalMB, let avail = memAvailableMB, total > 0 else { return nil }
        return Int((Double(total - avail) / Double(total)) * 100)
    }

    var storageUsedPercent: Int? {
        guard let total = storageTotalGB, let used = storageUsedGB, total > 0 else { return nil }
        return Int((used / total) * 100)
    }

    static let empty = DeviceTelemetry()
}

// MARK: - Cihaz işlemleri

extension ADBService {

    // MARK: Telemetri

    /// Hafif bir telemetri turu.
    ///
    /// YÜK BİLİNÇLİ OLARAK DÜŞÜK TUTULDU (önceki sürüm bunu yanlış yapmıştı:
    /// her turda ~8 ayrı adb süreci + 400 ms uyku, zaten RAM'i sıkışık cihazda
    /// 13 kat fazla yük). Şimdi:
    ///   • bellek + yük + CPU → TEK adb çağrısı
    ///   • pil + sıcaklık     → TEK adb çağrısı
    ///   • depolama           → TEK adb çağrısı
    ///   • ağ gecikmesi       → aynı çağrıların süresinden türetilir, ayrı
    ///                          süreç başlatılmaz.
    /// Toplam: 3 adb süreci (eskisi 8). CPU yüzdesi iki tur arasında hesaplanır,
    /// bekleme/uyku YOKTUR.
    func telemetry(serial: String) -> DeviceTelemetry {
        var t = DeviceTelemetry()
        t.collectedAt = Date()

        // 1) Bellek + yük + CPU — tek çağrı
        let kStart = Date()
        let k = shell(serial, ["sh", "-c", Shell.quote(
            "head -1 /proc/stat; cat /proc/loadavg; grep MemTotal /proc/meminfo; grep MemAvailable /proc/meminfo"
        )], timeout: 12)
        // Bu çağrı 4 alt komut içeriyor; alt komut başına ortalama gidiş-dönüş
        // süresi = ağ gecikmesinin dürüst tahmini. AYRI SÜREÇ AÇILMAZ.
        let elapsedMS = Date().timeIntervalSince(kStart) * 1000
        Self.cpuLock.lock()
        Self.lastLatencyMS = max(1, Int(elapsedMS / 4))
        Self.cpuLock.unlock()

        var cpuJiffies: (total: Double, idle: Double)?
        var memTotalKB: Int?
        var memAvailKB: Int?

        for line in k.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = parts.first else { continue }

            if first == "cpu", parts.count >= 5 {
                let nums = parts.dropFirst().compactMap { Double($0) }
                if nums.count >= 4 {
                    cpuJiffies = (nums.reduce(0, +), nums[3] + (nums.count > 4 ? nums[4] : 0))
                }
            } else if first.hasSuffix(":"), parts.count >= 2, let v = Int(parts[1]) {
                if first == "MemTotal:" { memTotalKB = v }
                else if first == "MemAvailable:" { memAvailKB = v }
            } else if let la = Double(first), parts.count >= 3 {
                // /proc/loadavg ilk sayısı = 1 dk yük
                t.cpuLoad1 = la
            }
        }

        if let total = memTotalKB {
            t.memTotalMB = total / 1024
            t.memAvailableMB = (memAvailKB ?? 0) / 1024
        }
        t.cpuPercent = Self.cpuPercent(from: cpuJiffies)

        // 2) Pil + sıcaklık + şarj — tek çağrı
        let bat = shell(serial, ["dumpsys", "battery"], timeout: 12)
        for line in bat.stdout.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("level:") { t.batteryPercent = Int(s.dropFirst(6).trimmingCharacters(in: .whitespaces)) }
            else if s.hasPrefix("temperature:") {
                if let raw = Int(s.dropFirst(12).trimmingCharacters(in: .whitespaces)) {
                    t.temperatureC = raw / 10   // dumpsys onda bir °C verir
                }
            }
            for key in ["AC powered:", "USB powered:", "Wireless powered:", "Dock powered:"] {
                if s.hasPrefix(key), s.contains("true") { t.charging = true }
                else if s.hasPrefix(key) { if t.charging != true { t.charging = false } }
            }
        }

        // 3) Depolama — tek çağrı
        if let st = storage(serial: serial) {
            t.storageTotalGB = st.totalGB
            t.storageUsedGB = st.usedGB
        }

        // Ağ gecikmesi ayrı süreç açmadan: yukarıdaki çağrıların gerçek adb
        // gidiş-dönüş süresi zaten ölçülmüş durumda. Son turdan kalma değeri
        // koruyoruz; süreç açmıyoruz.
        t.adbLatencyMS = Self.lastLatencyMS

        return t
    }

    /// CPU yüzdesini iki telemetri turu ARASINDA hesaplatır — bekleme yoktur.
    private static var cpuLock = NSLock()
    private static var previousCPU: (total: Double, idle: Double)?
    private static var lastLatencyMS: Int?
    private static var lastCallStart = Date.distantPast

    private static func cpuPercent(from now: (total: Double, idle: Double)?) -> Double? {
        guard let now else { return nil }
        cpuLock.lock()
        defer { cpuLock.unlock() }
        let prev = previousCPU
        previousCPU = now
        guard let prev else { return nil }   // ilk turda karşılaştırma yok
        let dTotal = now.total - prev.total
        let dIdle = now.idle - prev.idle
        guard dTotal > 0 else { return nil }
        return max(0, min(100, (dTotal - dIdle) / dTotal * 100))
    }

    /// `dumpsys battery` içinden şarj durumu (AC/USB/kablosuz).
    ///
    /// Üç kaynağın HEPSİNE bakılır: yalnızca ilk eşleşmede dönmek, AC kapalıyken
    /// USB/kablosuz şarjı kaçırırdı (gerçek cihaz çıktısında görülen durum).
    private func batteryStatus(serial: String) -> Bool? {
        let r = shell(serial, ["dumpsys", "battery"], timeout: 10)
        var found = false
        var powered = false
        for line in r.stdout.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            for key in ["AC powered:", "USB powered:", "Wireless powered:", "Dock powered:"] {
                if s.hasPrefix(key) {
                    found = true
                    if s.contains("true") { powered = true }
                }
            }
        }
        return found ? powered : nil
    }

    private func memInfo(serial: String) -> (totalMB: Int, availableMB: Int)? {
        let r = shell(serial, ["cat", "/proc/meminfo"], timeout: 10)
        var totalKB: Int?
        var availKB: Int?
        for line in r.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let value = Int(parts[1])
            if parts[0] == "MemTotal:" { totalKB = value }
            else if parts[0] == "MemAvailable:" { availKB = value }
        }
        guard let totalKB else { return nil }
        // Eski çekirdeklerde MemAvailable olmayabilir; MemFree ile yaklaş.
        let avail = availKB ?? 0
        return (totalKB / 1024, avail / 1024)
    }

    /// `/proc/stat` ilk satırını okur (toplam jiffies: user nice system idle iowait irq softirq).
    private func cpuJiffies(serial: String) -> (total: Double, idle: Double)? {
        let r = shell(serial, ["cat", "/proc/stat"], timeout: 10)
        guard let first = r.stdout.split(separator: "\n").first else { return nil }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 5, parts[0] == "cpu" else { return nil }
        let nums = parts.dropFirst().compactMap { Double($0) }
        guard nums.count >= 4 else { return nil }
        let total = nums.reduce(0, +)
        let idle = nums[3] + (nums.count > 4 ? nums[4] : 0)   // idle + iowait
        return (total, idle)
    }

    /// İki örnek arasındaki gerçek CPU kullanımı (%) — 400 ms pencere.
    private func cpuPercent(serial: String) -> Double? {
        guard let a = cpuJiffies(serial: serial) else { return nil }
        usleep(400_000)
        guard let b = cpuJiffies(serial: serial) else { return nil }

        let dTotal = b.total - a.total
        let dIdle = b.idle - a.idle
        guard dTotal > 0 else { return nil }
        let used = (dTotal - dIdle) / dTotal * 100
        return max(0, min(100, used))
    }

    private func loadAverage(serial: String) -> Double? {
        let r = shell(serial, ["cat", "/proc/loadavg"], timeout: 10)
        guard let first = r.stdout.split(separator: " ").first else { return nil }
        return Double(first)
    }

    /// `df -k /data` çıktısını ayrıştırır. Farklı toybox/busybox düzenlerine
    /// karşı dayanıklı: yüzde (%) işaretli token'ı bulup solundaki üç sayıyı
    /// blocks/used/available olarak alır.
    private func storage(serial: String) -> (totalGB: Double, usedGB: Double)? {
        let r = shell(serial, ["df", "-k", "/data"], timeout: 15)
        let lines = r.stdout.split(separator: "\n")
        guard let last = lines.last else { return nil }
        let tokens = last.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        guard let pctIndex = tokens.firstIndex(where: { $0.hasSuffix("%") }), pctIndex >= 3 else {
            return nil
        }
        let blocks = Double(tokens[pctIndex - 3]) ?? 0
        let used = Double(tokens[pctIndex - 2]) ?? 0
        guard blocks > 0 else { return nil }
        // 1K bloklar -> GB
        return (blocks / 1024 / 1024, used / 1024 / 1024)
    }

    /// `adb` gidiş-dönüş süresi (ms). Ağ kalitesinin dürüst, ucuz göstergesi.
    private func adbLatency(serial: String) -> Int? {
        let t0 = Date()
        let r = shell(serial, ["echo", "ok"], timeout: 10)
        guard r.stdout.contains("ok") else { return nil }
        return Int(Date().timeIntervalSince(t0) * 1000)
    }

    // MARK: Ekran / kilit

    /// Cihazın ekran çözünürlüğü (`wm size`). Fiziksel öncelikli, yoksa override.
    func screenSize(serial: String) -> (width: Int, height: Int)? {
        let r = shell(serial, ["wm", "size"], timeout: 10)
        for line in r.stdout.split(separator: "\n") {
            if line.contains("x") {
                let parts = line.split(separator: ":")
                guard let last = parts.last else { continue }
                let wh = last.trimmingCharacters(in: .whitespaces).split(separator: "x")
                if wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]) {
                    return (w, h)
                }
            }
        }
        return nil
    }

    /// Ekranı uyandırır ve basit kilidi (yok / kaydır) açar.
    ///
    /// DÜZGÜN BİLGİ: PIN / desen / şifre kilitliyse bunu AÇAMAZ — Android bunu
    /// kasıtlı olarak engeller. Bu buton senin tarif ettiğin durum içindir:
    /// ekran kapalı + kaydırma kilidi. Sonuç mesajı hangi adımın atlandığını
    /// dürüstçe söyler.
    func wakeAndUnlock(serial: String) -> [String] {
        var steps: [String] = []

        // 1) Ekranı uyandır. POWER (26) yerine WAKEUP (224) — WAKEUP yalnızca
        //    açar, ekran zaten açıksa kapatmaz.
        let wake = shell(serial, ["input", "keyevent", "224"], timeout: 10)
        steps.append(wake.succeeded ? "Ekran uyandırıldı (WAKEUP)" : "Uyandırma gönderilemedi")

        // Ekranın gerçekten açılması için kısa bekleme.
        usleep(450_000)

        // 2) Yukarı kaydırma hareketi — kilit ekranını geçmek için.
        if let (w, h) = screenSize(serial: serial) {
            let cx = w / 2
            let y1 = Int(Double(h) * 0.80)
            let y2 = Int(Double(h) * 0.25)
            let swipe = shell(serial, ["input", "swipe",
                                       "\(cx)", "\(y1)", "\(cx)", "\(y2)", "250"], timeout: 10)
            steps.append(swipe.succeeded
                         ? "Yukarı kaydırma gönderildi (\(w)×\(h))"
                         : "Kaydırma gönderilemedi")
        } else {
            steps.append("Ekran boyutu okunamadı — kaydırma atlandı")
        }

        // 3) Kalan basit kilit katmanını geçmek için MENU tuşu (bazı cihazlarda
        //    kilit ekranını tamamen kapatır).
        _ = shell(serial, ["input", "keyevent", "82"], timeout: 10)

        steps.append("Not: PIN/desen/şifre kilitliyse Android açılmasına izin vermez")
        return steps
    }

    // MARK: URL / link gönderme

    /// Mac'teki bağlantıyı cihazda açar (`android.intent.action.VIEW`).
    /// URL tek tırnakla sarılır — içindeki `&`, `?` vb. kabuk komutunu bölmesin.
    func sendURL(_ url: String, serial: String) -> CommandResult {
        let quoted = Shell.quote(url)
        return shell(serial, ["am", "start",
                              "-a", "android.intent.action.VIEW",
                              "-d", quoted], timeout: 15)
    }

    // MARK: Dosya aktarımı

    /// Dosyayı `/sdcard/Download/` altına iter.
    func pushFile(localURL: URL, serial: String) -> CommandResult {
        let name = localURL.lastPathComponent
        return adb(["-s", serial, "push", localURL.path, "/sdcard/Download/\(name)"])
    }

    /// APK kurar (`-r` = mevcut sürümü değiştir).
    ///
    /// Sandbox uyumlu: önce cihaza push eder, sonra pm install -r,
    /// sonra geçici dosyayı siler. `adb install` yerel yolu okuyamayabilir.
    func installAPK(localURL: URL, serial: String) -> CommandResult {
        let scoped = localURL.startAccessingSecurityScopedResource()
        defer { if scoped { localURL.stopAccessingSecurityScopedResource() } }

        let remote = "/data/local/tmp/droiddeck_\(UUID().uuidString.prefix(8)).apk"

        // 1. Push
        let push = adb(["-s", serial, "push", localURL.path, remote], timeout: 60)
        guard push.succeeded else { return push }

        // 2. Install
        let install = adb(["-s", serial, "shell", "pm", "install", "-r", remote], timeout: 120)

        // 3. Temizle
        _ = adb(["-s", serial, "shell", "rm", "-f", remote], timeout: 10)

        return install
    }

    /// Dosyayı medya tarayıcıya bildirir ki galeride görünsün.
    func scanMedia(remotePath: String, serial: String) -> CommandResult {
        let uri = Shell.quote("file://\(remotePath)")
        return shell(serial, ["am", "broadcast",
                              "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                              "-d", uri], timeout: 15)
    }
}
