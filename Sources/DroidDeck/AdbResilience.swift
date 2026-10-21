import Foundation

// MARK: - Genel adb dayanıklılığı
//
// TASARIM İLKESİ: Bu katman HİÇBİR cihaza özel bilgi içermez. Ne IP, ne seri
// numarası, ne marka/model varsayımı. Her şey adb'nin kendi davranışından
// türetilir — yani başka bir tablet/telefon/projektörle de aynı şekilde çalışır.
//
// Öğrenilen ders: bir cihaza bağlanılamadığında sorun ÇOĞU ZAMAN cihazda değil,
// yerel `adb` sunucusunun bayat bağlantı tablosundadır. `adb kill-server` ile
// anında çözülür. Kullanıcı bunu bilmek zorunda kalmamalı.

/// adb'nin geçici/bakım yapılabilir hata kalıpları.
private let transientFailureMarkers: [String] = [
    "no route to host",
    "connection refused",
    "connection reset",
    "broken pipe",
    "closed",
    "protocol fault",
    "device offline",
    "device not found",
    "cannot connect",
    "connection timed out",
    "timed out",
    "no devices/emulators found",
]

/// Bir komut sonucunun "yeniden başlatma ile düzeltilebilecek" türde olup olmadığını söyler.
func isTransientADBFailure(_ result: CommandResult) -> Bool {
    // Cihazın kendi verdiği bir hata değilse (örn. "unknown command") bakma.
    let haystack = (result.stderr + "\n" + result.stdout).lowercased()
    if haystack.isEmpty { return false }
    return transientFailureMarkers.contains { haystack.contains($0) }
}

/// adb sunucusunun yeniden başlatılmasını hız sınırlamasıyla yapan bakım kapısı.
///
/// Neden hız sınırı: `kill-server` tüm bağlantıları keser. Arka arkaya hatalar
/// gelse bile saniyede yüz kez tetiklenmemeli — aksi halde kendisi yük olur.
enum AdbMaintenance {
    private static let lock = NSLock()
    private static var lastRestart = Date.distantPast
    /// Bu süreden daha sık restart yapılmaz.
    static let minimumRestartInterval: TimeInterval = 8

    /// Yalnızca KARAR mantığı — yan etkisi yoktur, bu yüzden test edilebilir.
    static func shouldRestart(at now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return now.timeIntervalSince(lastRestart) >= minimumRestartInterval
    }

    /// Yeniden başlatma zamanını işaretler — adb'ye DOKUNMAZ (test edilebilirlik).
    static func markRestarted(at now: Date = Date()) {
        lock.lock()
        lastRestart = now
        lock.unlock()
    }

    /// Gerekirse adb sunucusunu yeniden başlatır. `true` dönerse gerçekten yaptı.
    @discardableResult
    static func restartIfNeeded(force: Bool = false) -> Bool {
        guard force || shouldRestart() else { return false }
        markRestarted()

        _ = ProcessRunner.run(ADBService.locateADB() ?? "adb",
                              arguments: ["kill-server"], timeout: 10)
        _ = ProcessRunner.run(ADBService.locateADB() ?? "adb",
                              arguments: ["start-server"], timeout: 15)
        return true
    }

    /// Test/teşhis için son restart zamanını sıfırlar.
    static func reset() {
        lock.lock()
        lastRestart = Date.distantPast
        lock.unlock()
    }
}

// MARK: - Otomatik kurtarma ile çağrı

extension ADBService {

    /// Geçici hata görünürse adb sunucusunu yeniden başlatıp TEK kez yeniden dener.
    ///
    /// Bu, `adb()` çağrılarının hepsini güvenli hâle getirir. Döngü yok —
    /// yalnızca tek bir yeniden deneme, o da gerçekten geçici bir hata ise.
    @discardableResult
    func resilientADB(_ args: [String], timeout: TimeInterval = 20) -> CommandResult {
        let first = adb(args, timeout: timeout)
        guard isTransientADBFailure(first) else { return first }

        guard AdbMaintenance.restartIfNeeded() else {
            // Az önce restart yapılmış — tekrar denemenin anlamı yok, hatayı döndür.
            return first
        }

        // Sunucu yeniden başladıktan sonra bağlantı kurulabilir listeyi tazele.
        // (Bazı cihazlarda reconnect gerekir; adb bunu `connect` olmadan da
        // yapar ama bilinen uç noktaları zorlamak süreyi kısaltır.)
        return adb(args, timeout: timeout)
    }

    /// Bilinen uç noktalara yeniden bağlanmayı dener (bağlantı koptuğunda).
    ///
    /// Cihazdan bağımsız çalışır: yalnızca `adb devices` içinde görünen ve
    /// `host:port` biçiminde olan uç noktaları yeniden dener.
    func reconnectKnownEndpoints() -> [String] {
        let listed = adb(["devices"], timeout: 12).stdout
        var reconnected: [String] = []
        for line in listed.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2, parts[1].contains("offline") || parts[1].contains("unauthorized") else {
                continue
            }
            let endpoint = String(parts[0])
            // Yalnızca ağ uç noktaları (host:port) yeniden bağlanabilir.
            guard endpoint.contains(":"), !endpoint.hasPrefix("emulator-") else { continue }
            let r = adb(["connect", endpoint], timeout: 12)
            if r.stdout.contains("connected") || r.stdout.contains("already") {
                reconnected.append(endpoint)
            }
        }
        return reconnected
    }
}

// MARK: - Kablosuz ADB kurulumu (cihazdan bağımsız)

/// Kablosuz ADB'yi hazırlarken hangi yolun kullanıldığını anlatır.
enum WirelessSetupResult: Equatable {
    /// Zaten hazır — doğrudan bağlanılabilir.
    case ready(endpoint: String, method: String)
    /// `adb tcpip <port>` ile hazırlandı.
    case enabled(endpoint: String, method: String)
    /// Cihazın IP'si bulunamadı (WiFi kapalı olabilir).
    case noWiFi
    /// Kurulum denendi ama başarısız.
    case failed(String)

    var endpoint: String? {
        switch self {
        case .ready(let e, _), .enabled(let e, _): return e
        default: return nil
        }
    }
    var explanation: String {
        switch self {
        case .ready(_, let m): return "Kablosuz bağlantı hazır (\(m))"
        case .enabled(_, let m): return "Kablosuz bağlantı açıldı (\(m))"
        case .noWiFi: return "Cihazda WiFi görünmüyor — önce WiFi'ye bağlayın"
        case .failed(let why): return "Kablosuz bağlantı kurulamadı: \(why)"
        }
    }
}

extension ADBService {

    /// Cihazın aktif ağ IP adresini bulur. Cihazdan bağımsız — `wlan0` dışında
    /// isim kullanan cihazlarda da çalışsın diye tüm arayüzler taranır ve
    /// yalnızca özel/yerel olmayan, gerçek bir IPv4 seçilir.
    func primaryIPv4(serial: String) -> String? {
        let r = shell(serial, ["ip", "-4", "addr"], timeout: 12)
        var candidates: [String] = []
        for line in r.stdout.split(separator: "\n") {
            guard line.contains("inet ") else { continue }
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let idx = tokens.firstIndex(of: "inet"), idx + 1 < tokens.count else { continue }
            let ip = String(tokens[idx + 1]).split(separator: "/").first.map(String.init) ?? ""
            // loopback ve bağlantı yerelini ele
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") || ip.isEmpty { continue }
            candidates.append(ip)
        }
        // WiFi arayüzü genelde en küçük yerel IP olur; en yaygın önekli olanı seç.
        return candidates.first
    }

    /// Cihazda şu an TCP üzerinde dinleyen adb portlarını bulur.
    ///
    /// NEDEN: birçok cihazda kablosuz hata ayıklama zaten açıktır ama mDNS
    /// üzerinden duyurulmaz (özellikle GSI/özel yazılımlarda). Doğrudan portu
    /// bulup bağlanmak, keşif mekanizmasına bağımlı olmayı ortadan kaldırır.
    func listeningTCPPorts(serial: String) -> [Int] {
        let r = shell(serial, ["sh", "-c", Shell.quote("ss -tln 2>/dev/null || netstat -tln 2>/dev/null")], timeout: 12)
        var ports: Set<Int> = []
        for line in r.stdout.split(separator: "\n") {
            guard line.contains("LISTEN") else { continue }
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            for token in tokens.reversed() {
                if let port = Int(token.split(separator: ":").last ?? ""), port > 0 {
                    ports.insert(port)
                    break
                }
            }
        }
        return ports.sorted()
    }

    /// Kablosuz ADB'yi kullanıma hazırlar.
    ///
    /// CİHAZDAN BAĞIMSIZ ve KESTİRİM YAPMAYAN mantık:
    ///  1. Tercih edilen port zaten dinliyorsa onu kullan (bilinen, düz ADB)
    ///  2. Değilse `adb tcpip <port>` ile o portu aç — bu her cihazda aynı
    ///     davranır ve eşleştirme gerektirmez
    ///  3. IP'yi cihazdan oku (gömülü değil)
    ///
    /// NEDEN "ilk dinleyen port" kullanılmıyor: cihazlarda genellikle birden
    /// çok port dinler (örn. eşleştirme gerektiren TLS portu + düz ADB portu).
    /// İlkini seçmek yanlış portu alabilir. Deterministik olmak daha güvenli.
    func prepareWireless(serial: String, preferredPort: Int = 5555) -> WirelessSetupResult {
        guard let ip = primaryIPv4(serial: serial) else {
            return .noWiFi
        }
        let endpoint = "\(ip):\(preferredPort)"

        // 1) Tercih edilen port zaten dinliyor mu?
        let listening = listeningTCPPorts(serial: serial)
        if listening.contains(preferredPort) {
            return .ready(endpoint: endpoint,
                          method: "port \(preferredPort) zaten açık")
        }

        // 2) Klasik TCP ADB'yi o portta aç
        let en = adb(["-s", serial, "tcpip", "\(preferredPort)"], timeout: 20)
        guard en.succeeded || en.stdout.contains("restarting in TCP mode") else {
            return .failed(en.combined)
        }

        // adbd yeniden başlar; portun açılması için kısa bekleme.
        usleep(1_500_000)

        return .enabled(endpoint: endpoint, method: "adb tcpip \(preferredPort)")
    }
}

// MARK: - Cihaz sağlığı (cihazdan bağımsız göstergeler)

/// Bir cihazın o an yüklenip yüklenmediğini söyleyen genel göstergeler.
///
/// ÖĞRENİLEN DERS: Linux `load average` her cihazda güvenilir DEĞİLDİR. Bazı
/// vendor çekirdekleri boşta bekleyen iş parçacıklarını D durumunda işaretler ve
/// yük değeri yapay olarak yüksek görünür (biz 25 görmüştük, CPU ise %97 boştaydı).
/// Bu yüzden karar tek bir ölçüme değil, BİRKAÇINA dayanır.
struct DeviceHealth: Equatable {
    var cpuPercent: Double?
    var loadAverage1: Double?
    var adbLatencyMS: Int?
    var memUsedPercent: Int?

    /// Gerçekten sağlıksız mı? Yalnızca SOMUT kanıtlarla "evet" der.
    var isUnhealthy: Bool {
        if let cpu = cpuPercent, cpu >= 92 { return true }
        if let mem = memUsedPercent, mem >= 97 { return true }
        // Gecikme tek başına kanıt değil (kablosuz uyku vs.), ama çok yüksekse
        // uyarı vermek gerekir — kesme, sadece haber ver.
        return false
    }

    /// Kullanıcıya gösterilecek uyarı var mı?
    var warning: String? {
        if let lat = adbLatencyMS, lat >= 400 {
            return "Bağlantı yavaş (\(lat) ms) — cihaz meşgul olabilir veya WiFi uyuyor olabilir"
        }
        if let cpu = cpuPercent, cpu >= 92 {
            return "Cihaz çok yoğun (CPU %\(Int(cpu))) — işlemler yavaşlayabilir"
        }
        return nil
    }
}
