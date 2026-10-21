import Foundation

// MARK: - Komut çalıştırma

struct CommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let timedOut: Bool

    var succeeded: Bool { exitCode == 0 && !timedOut }
    /// Hangi çıktının dolu olduğuna göre tek bir metin döndürür.
    var combined: String {
        // ZAMAN AŞIMINDA stdout PARÇALI olabilir. Eskiden stdout tercih
        // ediliyordu; bu, gerçek hata mesajını gizleyip yarım çıktı gösteriyordu.
        if timedOut {
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Zaman aşımı" + (err.isEmpty ? "" : " — \(err)")
                + (out.isEmpty ? "" : "\nKısmi çıktı: \(out)")
        }
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return stdout }
        return stderr
    }
}

/// Pipe okumalarını güvenli biçimde toplamak için kutu (eşzamanlı yazım uyarısı almamak için).
private final class DataBox {
    private let lock = NSLock()
    private var storage = Data()

    /// Kilitle okunur/yazılır: zaman aşımında okuyucu iş parçacığı hâlâ yazarken
    /// sonuç okunabilir; bu yarış veri bozulmasına yol açabilir.
    var data: Data {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }
}

enum ProcessRunner {

    /// Zaman aşımına uğrayan süreci kesin olarak sonlandırır.
    ///
    /// `terminate()` (SIGTERM) bazı süreçlerce yok sayılabilir; bu durumda
    /// `readDataToEndOfFile` sonsuza dek bloke olur (iş parçacığı sızıntısı) ve
    /// sonuç verisi hâlâ yazılıyorken okunur. Önce SIGTERM, sonuç vermezse
    /// SIGKILL gönderilir ve okuyucuların bitmesi beklenir.
    private static func forceTerminate(_ process: Process, group: DispatchGroup) {
        process.terminate()
        if group.wait(timeout: .now() + 2) == .timedOut {
            // SIGTERM'i yok sayan süreçleri kesin olarak sonlandır.
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        // Okuyucuların DataBox'a yazmayı BIRAKMASINI bekle: sonuç verisi ancak
        // ondan sonra okunabilir. Bitmezlerse okuma eksik olabilir ama en
        // azından COW buffer üzerinde okuma/yazma yarışı olmaz.
        _ = group.wait(timeout: .now() + 3)
        process.waitUntilExit()
    }

    /// Bir dış süreci çalıştırır, stdout/stderr'ı toplar ve zaman aşımına karşı korur.
    @discardableResult
    static func run(_ executable: String,
                    arguments: [String],
                    timeout: TimeInterval = 20,
                    environment: [String: String]? = nil) -> CommandResult {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        if let environment {
            env.merge(environment) { _, new in new }
        }
        process.environment = env
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return CommandResult(
                stdout: "",
                stderr: "Süreç başlatılamadı: \(error.localizedDescription)",
                exitCode: -1,
                timedOut: false
            )
        }

        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "droiddeck.process.read", attributes: .concurrent)

        group.enter()
        queue.async {
            stdoutBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        queue.async {
            stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            forceTerminate(process, group: group)
            return CommandResult(
                stdout: String(data: stdoutBox.data, encoding: .utf8) ?? "",
                stderr: "Zaman aşımı (\(Int(timeout)) saniye)",
                exitCode: -2,
                timedOut: true
            )
        }

        process.waitUntilExit()

        return CommandResult(
            stdout: String(data: stdoutBox.data, encoding: .utf8) ?? "",
            stderr: String(data: stderrBox.data, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus,
            timedOut: false
        )
    }

    /// Stdin'e metin yazarak çalıştırma (`adb pair` için — kod komut satırına düşmez).
    @discardableResult
    static func run(_ executable: String,
                    arguments: [String],
                    input: String,
                    timeout: TimeInterval = 30) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return CommandResult(stdout: "",
                                 stderr: "Süreç başlatılamadı: \(error.localizedDescription)",
                                 exitCode: -1,
                                 timedOut: false)
        }

        // Kodu yaz ve stdin'i kapat — süreç yanıtı bu noktadan sonra üretir.
        do {
            // Throw eden API: çocuk stdin'i okumadan çıkarsa EPIPE, yakalanamayan
            // ObjC exception/SIGPIPE yerine normal hataya dönüşür.
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data((input + "\n").utf8))
        } catch {
            // Çocuk girdiyi okumuyor — çıktısı yine toplanır.
        }
        try? stdinPipe.fileHandleForWriting.close()

        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "droiddeck.process.input", attributes: .concurrent)

        group.enter()
        queue.async {
            outBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        queue.async {
            errBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            forceTerminate(process, group: group)
            return CommandResult(stdout: String(data: outBox.data, encoding: .utf8) ?? "",
                                 stderr: "Zaman aşımı (\(Int(timeout)) saniye)",
                                 exitCode: -2,
                                 timedOut: true)
        }
        process.waitUntilExit()

        return CommandResult(stdout: String(data: outBox.data, encoding: .utf8) ?? "",
                             stderr: String(data: errBox.data, encoding: .utf8) ?? "",
                             exitCode: process.terminationStatus,
                             timedOut: false)
    }

    /// Süreci başlatır ve sonucunu beklemez (örn. scrcpy penceresi).
    static func launchDetached(_ executable: String,
                               arguments: [String],
                               environment: [String: String]? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        if let environment {
            env.merge(environment) { _, new in new }
        }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }
}

// MARK: - İkili çıktı

struct CommandDataResult {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
    var succeeded: Bool { exitCode == 0 && !stdout.isEmpty }
}

extension ProcessRunner {

    /// İkili güvenli çalıştırma (`adb exec-out` için). Çıktıyı Data olarak döndürür.
    static func runData(_ executable: String,
                        arguments: [String],
                        timeout: TimeInterval = 45) -> CommandDataResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return CommandDataResult(stdout: Data(),
                                     stderr: Data(error.localizedDescription.utf8),
                                     exitCode: -1)
        }

        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "droiddeck.process.data", attributes: .concurrent)

        group.enter()
        queue.async {
            outBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        queue.async {
            errBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            forceTerminate(process, group: group)
        }
        process.waitUntilExit()

        return CommandDataResult(stdout: outBox.data,
                                 stderr: errBox.data,
                                 exitCode: process.terminationStatus)
    }
}

// MARK: - Yardımcılar

enum Shell {
    /// Bir argümanı cihaz kabuğu için tek tırnakla güvenli biçimde sarar.
    ///
    /// `adb shell ...` argümanları boşlukla birleştirilip `/system/bin/sh -c`
    /// ile çalıştırılır. URL'lerdeki `&`, `?`, `*`, `(`, `)` kaçırılmazsa
    /// kabuk komutu böler / yerine koyma yapar — yani bu bir güvenlik
    /// gereksinimidir, yalnızca düzgün görünüm değil.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `input text` metnini cihaz kabuğu için güvenli hâle getirir.
    ///
    /// NEDEN KAPSAMLI: `adb shell ...` argümanları boşlukla birleştirilip
    /// cihazdaki `/system/bin/sh -c` üzerinden çalıştırılır. Kaçırılmamış bir
    /// backtick, `$`, `*` vb. cihazda **komut çalıştırabilir**. Örneğin
    /// yapıştırılan `` `pm uninstall com.foo` `` metni kabuk tarafından
    /// yerine koyma ile çalıştırılır.
    ///
    /// Ayrıca `input text` kendi tarafında `%s`'yi boşluğa çevirir; gerçek
    /// boşluklar bu yüzden `%s` ile gönderilir.
    static func escapeForInputText(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count * 2)

        for scalar in text.unicodeScalars {
            switch scalar {
            case " ", "\n", "\r", "\t":
                out += "%s"
            case "\\", "`", "$", "\"", "'", "!", "#", "&", ";", "|",
                 "(", ")", "<", ">", "{", "}", "[", "]", "*", "?", "~", "^":
                out += "\\\(scalar)"
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// `com.google.android.youtube` -> `Youtube`
    static func friendlyName(fromPackage packageName: String) -> String {
        let last = packageName.split(separator: ".").last.map(String.init) ?? packageName
        var out = ""
        for (index, character) in last.enumerated() {
            if character == "_" || character == "-" {
                out += " "
                continue
            }
            if character.isUppercase, index > 0, !last[last.index(last.startIndex, offsetBy: index - 1)].isUppercase {
                out += " "
            }
            out.append(character)
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return packageName }
        return first.uppercased() + trimmed.dropFirst()
    }
}
