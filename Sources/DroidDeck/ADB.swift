import Foundation

/// `adb` ve `scrcpy` komut satırı araçlarını saran servis katmanı.
struct ADBService {

    let adbPath: String

    // MARK: - Konumlandırma

    /// Kullanılabilir `adb` yolunu bulur (Homebrew, Android SDK, PATH).
    static func locateADB() -> String? {
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
            "\(NSHomeDirectory())/Android/sdk/platform-tools/adb",
            "/usr/bin/adb"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let found = ProcessRunner.run("/usr/bin/env", arguments: ["which", "adb"], timeout: 5)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !found.isEmpty, FileManager.default.isExecutableFile(atPath: found) {
            return found
        }
        return nil
    }

    /// `scrcpy` yolunu bulur. Yoksa nil döner.
    static func locateScrcpy() -> String? {
        let candidates = [
            "/opt/homebrew/bin/scrcpy",
            "/usr/local/bin/scrcpy",
            "\(NSHomeDirectory())/bin/scrcpy"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let found = ProcessRunner.run("/usr/bin/env", arguments: ["which", "scrcpy"], timeout: 5)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !found.isEmpty, FileManager.default.isExecutableFile(atPath: found) {
            return found
        }
        return nil
    }

    /// `scrcpy-server` dosyasını bulur (video akışı için cihaza itilir).
    static func locateScrcpyServer() -> String? {
        let direct = [
            "/opt/homebrew/share/scrcpy/scrcpy-server",
            "/usr/local/share/scrcpy/scrcpy-server",
            "/opt/homebrew/opt/scrcpy/share/scrcpy/scrcpy-server",
        ]
        for path in direct where FileManager.default.fileExists(atPath: path) {
            return path
        }

        // Homebrew Cellar: sürüme göre değişen dizin.
        let cellarDirs = ["/opt/homebrew/Cellar/scrcpy", "/usr/local/Cellar/scrcpy"]
        for cellar in cellarDirs {
            guard let versions = try? FileManager.default.contentsOfDirectory(atPath: cellar) else { continue }
            for version in versions.sorted().reversed() {
                let candidate = "\(cellar)/\(version)/share/scrcpy/scrcpy-server"
                if FileManager.default.fileExists(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Cihaz pil bilgisi (sıcaklık ve seviye) — termal koruma için.
    struct BatteryInfo {
        var levelPercent: Int?
        var temperatureC: Int?     // derece (tam sayı)
        var status: String?
    }

    func batteryInfo(serial: String) -> BatteryInfo {
        let result = shell(serial, ["dumpsys", "battery"], timeout: 15)
        var info = BatteryInfo()
        for rawLine in result.stdout.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("level:") {
                info.levelPercent = Int(line.dropFirst("level:".count)
                    .trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("temperature:") {
                // Android onda bir derece verir: "temperature: 285" -> 28.5°C
                if let raw = Int(line.dropFirst("temperature:".count)
                    .trimmingCharacters(in: .whitespaces)) {
                    info.temperatureC = Int((Double(raw) / 10.0).rounded())
                }
            } else if line.hasPrefix("status:") {
                info.status = String(line.dropFirst("status:".count)
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        return info
    }

    // MARK: - Temel çağrı

    @discardableResult
    func adb(_ args: [String], timeout: TimeInterval = 20) -> CommandResult {
        ProcessRunner.run(adbPath, arguments: args, timeout: timeout)
    }

    @discardableResult
    func shell(_ serial: String, _ args: [String], timeout: TimeInterval = 20) -> CommandResult {
        adb(["-s", serial, "shell"] + args, timeout: timeout)
    }

    // MARK: - Keşif

    func listDevices() -> [AndroidDevice] {
        Self.parseDevices(adb(["devices", "-l"], timeout: 12).stdout)
    }

    func listMDNSServices() -> [MDNSService] {
        Self.parseMDNSServices(adb(["mdns", "services"], timeout: 12).stdout)
    }

    /// Cihazla eşleşme yapar. Kod stdin üzerinden gönderilir (komut satırına düşmez).
    /// `endpoint` biçiminde `ip:port` bekler — port, `_adb-tls-pairing._tcp` servisinden gelir.
    func pair(endpoint: String, code: String) -> CommandResult {
        ProcessRunner.run(adbPath,
                          arguments: ["pair", endpoint],
                          input: code.trimmingCharacters(in: .whitespacesAndNewlines),
                          timeout: 30)
    }

    /// `adb connect ip:port` ile elle bağlanır.
    func connect(to endpoint: String) -> CommandResult {
        adb(["connect", endpoint], timeout: 15)
    }

    /// `adb connect` sonucunu ÇIKTIDAN doğrular — exit koduna güvenmez.
    ///
    /// NEDEN: `adb connect` bağlantı BAŞARISIZ olsa bile **exit kodu 0** döner.
    /// (Canlı doğrulandı: `adb connect 127.0.0.1:1` → "failed to connect…
    /// Connection refused", EXIT:0.) Exit koduna dayanmak "Bağlandı" yalanını
    /// üretir: kullanıcı bağlandığını görür ama komutlar hiç gitmez.
    func connectVerified(to endpoint: String) -> (ok: Bool, message: String) {
        // `resilientADB`: geçici hata görünürse adb sunucusunu yeniden başlatıp
        // TEK kez yeniden dener. (Eskiden bu fonksiyon hiç çağrılmıyordu —
        // dayanıklılık katmanı ölü koddu.)
        let r = resilientADB(["connect", endpoint], timeout: 15)
        let text = (r.stdout + "\n" + r.stderr)
        let lower = text.lowercased()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if r.timedOut {
            return (false, "Bağlantı zaman aşımına uğradı")
        }
        if lower.contains("already connected") || lower.contains("connected to") {
            return (true, trimmed)
        }
        return (false, trimmed.isEmpty ? "Bağlantı kurulamadı" : trimmed)
    }

    /// Cihaz listesini okur. BAŞARISIZ tarama ile BOŞ liste birbirinden
    /// ayrılır — aksi halde geçici bir kesinti "cihaz yok" diye yorumlanıp
    /// kullanıcının oturumu (seçim, önizleme) silinir.
    func listDevicesChecked() -> (devices: [AndroidDevice], ok: Bool) {
        // `resilientADB`: bayat sunucuda tarama boş dönerdi. Geçici hatada
        // tek kez yeniden denenir.
        let r = resilientADB(["devices", "-l"], timeout: 15)
        // Zaman aşımı veya hatalı sonuç = liste GEÇERSİZ, boş DEĞİL.
        guard r.succeeded else { return ([], false) }
        return (Self.parseDevices(r.stdout), true)
    }

    /// Bağlantıyı keser.
    func disconnect(_ endpoint: String) -> CommandResult {
        adb(["disconnect", endpoint], timeout: 10)
    }

    /// ADB sunucusunu yeniden başlatır.
    func restartServer() -> CommandResult {
        adb(["kill-server"], timeout: 10)
        return adb(["start-server"], timeout: 20)
    }

    // MARK: - Kontrol

    /// KeyEvent gönderir (tuş basımı).
    @discardableResult
    func keyevent(_ serial: String, _ keyCode: KeyCode) -> CommandResult {
        keyevent(serial, rawCode: keyCode.rawValue)
    }

    /// Ham keyevent kodu gönderir.
    @discardableResult
    func keyevent(_ serial: String, rawCode: Int) -> CommandResult {
        shell(serial, ["input", "keyevent", "\(rawCode)"])
    }

    /// Medya aksiyonu gönderir (play/pause vb.).
    @discardableResult
    func media(_ serial: String, _ action: MediaAction) -> CommandResult {
        shell(serial, ["media", "dispatch", action.rawValue])
    }

    /// Metni odaklı alana yazar.
    @discardableResult
    func typeText(_ serial: String, _ text: String) -> CommandResult {
        shell(serial, ["input", "text", Shell.escapeForInputText(text)], timeout: 25)
    }

    /// Dokunma simüle eder.
    @discardableResult
    func tap(_ serial: String, x: Int, y: Int) -> CommandResult {
        shell(serial, ["input", "tap", "\(x)", "\(y)"])
    }

    /// Kaydırma simüle eder.
    @discardableResult
    func swipe(_ serial: String, x1: Int, y1: Int, x2: Int, y2: Int, durationMS: Int = 300) -> CommandResult {
        shell(serial, ["input", "swipe", "\(x1)", "\(y1)", "\(x2)", "\(y2)", "\(durationMS)"])
    }

    // MARK: - Uygulamalar

    /// Ana ekranda ikonu olan (başlatılabilir) uygulamaları listeler.
    /// Bu, cihazın uygulama çekmecesinde görünen listedir.
    func listLaunchableApps(_ serial: String) -> [AndroidApp] {
        let result = shell(serial,
                           ["cmd", "package", "query-activities", "--brief",
                            "-a", "android.intent.action.MAIN",
                            "-c", "android.intent.category.LAUNCHER"],
                           timeout: 30)
        let apps = Self.parseLaunchableApps(result.stdout)
        if !apps.isEmpty { return apps }

        // Eski cihazlarda `cmd package query-activities` olmayabilir.
        return listThirdPartyApps(serial)
    }

    /// Kurulu üçüncü parti uygulamaları listeler.
    func listThirdPartyApps(_ serial: String) -> [AndroidApp] {
        Self.parsePackages(shell(serial, ["pm", "list", "packages", "-3"], timeout: 25).stdout)
    }

    /// Bir uygulamayı başlatır. Bileşen biliniyorsa doğrudan onu açar.
    @discardableResult
    func launchApp(_ serial: String, packageName: String, componentName: String? = nil) -> CommandResult {
        if let componentName, !componentName.isEmpty {
            return shell(serial, ["am", "start", "-n", componentName], timeout: 25)
        }
        return shell(serial,
                     ["monkey", "-p", packageName, "-c", "android.intent.category.LAUNCHER", "1"],
                     timeout: 25)
    }

    /// Uygulamayı zorla durdurur.
    @discardableResult
    func forceStop(_ serial: String, packageName: String) -> CommandResult {
        shell(serial, ["am", "force-stop", packageName], timeout: 15)
    }

    // MARK: - Ekran

    /// scrcpy'yi cihaz için ayrı bir pencerede başlatır.
    @discardableResult
    func launchScrcpy(serial: String,
                      maxSize: Int = 0,
                      maxFPS: Int = 20,
                      bitRateMbps: Int = 1,
                      turnScreenOff: Bool = false) -> Result<Void, Error> {
        guard let scrcpy = Self.locateScrcpy() else {
            return .failure(NSError(
                domain: "DroidCtrl",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "scrcpy bulunamadı. `brew install scrcpy` ile kurun."]
            ))
        }

        var args = [
            "--serial", serial,
            "--max-fps", "\(maxFPS)",
            "--video-bit-rate", "\(bitRateMbps)M",
            "--window-title", "DroidCtrl · \(serial)"
        ]
        if maxSize > 0 {
            args.append(contentsOf: ["--max-size", "\(maxSize)"])
        }
        if turnScreenOff {
            args.append(contentsOf: ["--turn-screen-off", "--stay-awake"])
        }

        do {
            try ProcessRunner.launchDetached(scrcpy, arguments: args)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Tanılama

    func deviceProperties(_ serial: String) -> [String: String] {
        Self.parseProperties(shell(serial, ["getprop"], timeout: 20).stdout)
    }
}

// MARK: - Saf ayrıştırıcılar
// Gerçek cihaz çıktısıyla doğrulanmış; `--selftest` bunları test eder.

extension ADBService {

    /// `adb devices -l` çıktısı.
    static func parseDevices(_ output: String) -> [AndroidDevice] {
        var devices: [AndroidDevice] = []

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of devices") || line.hasPrefix("*") { continue }

            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 2 else { continue }

            let serial = fields[0]
            let state = DeviceState(rawValue: fields[1]) ?? .unknown

            var model: String?
            var product: String?
            var transportID: String?
            for field in fields.dropFirst(2) {
                guard let colon = field.firstIndex(of: ":") else { continue }
                let key = String(field[..<colon])
                let value = String(field[field.index(after: colon)...])
                switch key {
                case "model": model = value
                case "product": product = value
                case "transport_id": transportID = value
                default: break
                }
            }

            devices.append(AndroidDevice(serial: serial,
                                         state: state,
                                         model: model,
                                         product: product,
                                         transportID: transportID))
        }
        return devices
    }

    /// `adb mdns services` çıktısı. Alanlar hem boşluk hem tab ile ayrılabilir.
    static func parseMDNSServices(_ output: String) -> [MDNSService] {
        var services: [MDNSService] = []

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of") || line.hasPrefix("*") { continue }

            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 3 else { continue }

            let instance = fields[0]
            let serviceType = fields[1]
            let endpoint = fields[2]
            guard endpoint.contains(":") else { continue }

            services.append(MDNSService(instance: instance,
                                        serviceType: serviceType,
                                        endpoint: endpoint))
        }
        return services
    }

    /// `getprop` çıktısı — satır biçimi `[anahtar]: [değer]`.
    static func parseProperties(_ output: String) -> [String: String] {
        var props: [String: String] = [:]

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), line.hasSuffix("]") else { continue }

            let inner = line.dropFirst().dropLast()
            guard let separator = inner.range(of: "]: [") else { continue }

            let key = String(inner[inner.startIndex..<separator.lowerBound])
            let value = String(inner[separator.upperBound...])
            props[key] = value
        }
        return props
    }

    /// `pm list packages` çıktısı.
    static func parsePackages(_ output: String) -> [AndroidApp] {
        var apps: [AndroidApp] = []

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("package:") else { continue }
            let name = String(line.dropFirst("package:".count))
            if !name.isEmpty {
                apps.append(AndroidApp(packageName: name))
            }
        }
        return apps.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// `cmd package query-activities --brief` çıktısı.
    /// Satır biçimi: `com.pkg/.Activity` (diğer satırlarda boşluk bulunur).
    static func parseLaunchableApps(_ output: String) -> [AndroidApp] {
        var apps: [AndroidApp] = []
        var seen = Set<String>()

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.contains(" ") || !line.contains("/") { continue }

            guard let slash = line.firstIndex(of: "/") else { continue }
            let packageName = String(line[..<slash])
            let component = String(line[line.index(after: slash)...])

            guard packageName.contains("."), !component.isEmpty,
                  isIdentifier(packageName), isIdentifier(component),
                  !seen.contains(packageName) else { continue }

            seen.insert(packageName)
            apps.append(AndroidApp(packageName: packageName,
                                   componentName: "\(packageName)/\(component)"))
        }
        return apps.sorted { $0.packageName < $1.packageName }
    }

    private static func isIdentifier(_ text: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._$"))
        return text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
