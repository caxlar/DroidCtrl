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
///
/// YALNIZCA stderr üzerinde aranır. Önceleri stdout da taranıyordu; bu,
/// `dumpsys wifi` çıktısında geçen "closed" gibi kelimelerin gerçek bir hatayı
/// "geçici" göstermesine yol açıyordu.
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
    "error: no devices/emulators found",
    "error: device",
    "failed to connect",
]

/// Bir komut sonucunun "yeniden başlatma ile düzeltilebilecek" türde olup olmadığını söyler.
func isTransientADBFailure(_ result: CommandResult) -> Bool {
    // ZAMAN AŞIMI da geçici sayılmalı: jitter'lı WiFi'deki asıl hata biçimi
    // budur. Eskiden yalnızca metne bakılıyordu ve Türkçe "Zaman aşımı (…)"
    // metni hiç tanınmıyordu — yani en sık görülen hata hiçbir zaman
    // "geçici" sayılmıyordu.
    if result.timedOut { return true }

    // Yalnızca HATA akışına bak. stdout, komut çıktısıdır; içinde geçen
    // kelimeler hata anlamına gelmez.
    let haystack = result.stderr.lowercased()
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
    ///
    /// Kontrol + işaretleme TEK kilit ediniminde yapılır. Eskiden ikisi ayrı
    /// kilitlenmişti ve iki iş parçacığı aynı anda geçerse **iki kez**
    /// kill-server çalışabiliyordu.
    @discardableResult
    static func restartIfNeeded(force: Bool = false) -> Bool {
        lock.lock()
        let since = Date().timeIntervalSince(lastRestart)
        guard force || since >= minimumRestartInterval else {
            lock.unlock()
            return false
        }
        lastRestart = Date()
        lock.unlock()

        guard let adbPath = ADBService.locateADB() else {
            // adb bulunamadıysa "başardım" deme — çağıran yanılmamalı.
            return false
        }
        _ = ProcessRunner.run(adbPath, arguments: ["kill-server"], timeout: 10)
        let started = ProcessRunner.run(adbPath, arguments: ["start-server"], timeout: 20)
        return started.succeeded
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
