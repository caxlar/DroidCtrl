import Foundation
import CoreVideo
import CoreImage
import AppKit

/// Uygulama etiketlerini (gerçek adları) APK'dan çözen cihaz tarafı katman.
enum LabelCLI {

    /// Tek bir telemetri turu — canlı doğrulama için (`--telemetry`).
    static func telemetryProbe() {
        guard let adbPath = ADBService.locateADB() else {
            FileHandle.standardError.write(Data("adb bulunamadı\n".utf8)); exit(1)
        }
        let adb = ADBService(adbPath: adbPath)
        guard let device = adb.listDevices().first(where: { $0.state.isControllable }) else {
            print("kontrol edilebilir cihaz yok"); exit(2)
        }
        print("cihaz      : \(device.serial)")
        let t = adb.telemetry(serial: device.serial)
        print("pil        : \(t.batteryPercent.map { "\($0)%" } ?? "nil")")
        print("sıcaklık   : \(t.temperatureC.map { "\($0)°C" } ?? "nil")")
        print("şarj       : \(t.charging.map { $0 ? "evet" : "hayır" } ?? "nil")")
        if let total = t.memTotalMB, let avail = t.memAvailableMB {
            print("RAM        : \(avail)/\(total) MB")
        } else {
            print("RAM        : nil")
        }
        print("RAM %      : \(t.memUsedPercent.map { "\($0)%" } ?? "nil")")
        print("CPU %      : \(t.cpuPercent.map { String(format: "%.1f", $0) } ?? "nil")")
        print("yük (1dk)  : \(t.cpuLoad1.map { String(format: "%.2f", $0) } ?? "nil")")
        if let used = t.storageUsedGB, let total = t.storageTotalGB {
            print("depolama   : \(String(format: "%.1f / %.1f GB", used, total))")
        } else {
            print("depolama   : nil")
        }
        print("bağlantı   : \(t.adbLatencyMS.map { "\($0) ms" } ?? "nil")")
        exit(0)
    }

    // MARK: - Dosyadan (test)

    static func fromFiles(manifestPath: String, arscPath: String) -> Never {
        guard let manifest = FileManager.default.contents(atPath: manifestPath) else {
            FileHandle.standardError.write(Data("Manifest okunamadı: \(manifestPath)\n".utf8))
            exit(1)
        }
        let arsc = FileManager.default.contents(atPath: arscPath)

        let info = AxmlParser.parse(manifest)
        print("applicationLabel : \(describe(info.applicationLabel))")
        print("launcherLabel    : \(describe(info.launcherLabel))")
        print("launcherActivity : \(info.launcherActivity ?? "-")")

        if let arsc {
            let result = ApkLabel.resolve(packageName: "(dosya)", manifest: manifest, arsc: arsc)
            print("çözülen etiket   : \(result.label ?? "-")  [kaynak: \(result.source)]")
        } else {
            print("(resources.arsc verilmedi — yalnızca manifest ayrıştırıldı)")
        }
        exit(0)
    }

    /// Sütun hizalaması için sabit genişliğe yayar. (`String(format:)` ile
    /// Swift `String` kullanmak segfault'a yol açar; `%s` yalnızca C string içindir.)
    private static func pad(_ text: String, _ width: Int) -> String {
        let truncated = String(text.prefix(width))
        if truncated.count >= width { return truncated }
        return truncated + String(repeating: " ", count: width - truncated.count)
    }

    private static func describe(_ ref: LabelRef?) -> String {
        switch ref {
        case .none: return "(yok)"
        case .literal(let s): return "literal: \"\(s)\""
        case .resource(let id): return String(format: "kaynak: 0x%08x", id)
        }
    }

    // MARK: - ARSC izleme (tanılama)

    /// Verilen kaynak kimliğinin her yapılandırmada nasıl çözüldüğünü gösterir.
    static func arscTrace(arscPath: String, idHex: String) -> Never {
        guard let data = FileManager.default.contents(atPath: arscPath) else {
            print("arsc okunamadı: \(arscPath)")
            exit(1)
        }
        guard let table = ArscTable.parse(data) else {
            print("arsc ayrıştırılamadı")
            exit(1)
        }

        let cleaned = idHex.hasPrefix("0x") ? String(idHex.dropFirst(2)) : idHex
        guard let id = UInt32(cleaned, radix: 16) else {
            print("geçersiz kimlik: \(idHex)")
            exit(1)
        }

        let typeId = (id >> 16) & 0xFF
        let entryId = Int(id & 0xFFFF)
        print("kaynak 0x\(cleaned)  →  typeId=\(typeId)  entryId=\(entryId)")
        print("")

        for pkg in table.packages {
            print("paket id=\(pkg.id)  ad=\(pkg.name)")
            let matching = pkg.types.filter { Int($0.typeId) + pkg.typeIdOffset == Int(typeId) }
            if matching.isEmpty {
                print("  (bu typeId için chunk yok — toplam chunk: \(pkg.types.count))")
            }
            for t in matching {
                let resolved: String
                if let v = t.entries[entryId] {
                    if v.dataType == 0x03 {
                        resolved = table.globalStrings[Int(v.data)] ?? "(dize yok, idx=\(v.data))"
                    } else {
                        resolved = "dataType=0x\(String(v.dataType, radix: 16)) data=0x\(String(v.data, radix: 16))"
                    }
                } else {
                    resolved = "(bu yapılandırmada girdi yok)"
                }
                print("  locale=\(t.locale ?? "default")  girdi sayısı=\(t.entries.count)  →  \(resolved)")
            }
        }
        exit(0)
    }

    // MARK: - ARSC ham döküm (tanılama)

    /// Bir tip chunk'ının ham ofset tablosunu ve girdi baytlarını gösterir.
    static func arscRaw(arscPath: String, typeId: Int, entryId: Int) -> Never {
        guard let data = FileManager.default.contents(atPath: arscPath) else {
            print("arsc okunamadı"); exit(1)
        }
        let bytes = [UInt8](data)

        var r = ByteReader(bytes: bytes, pos: 0)
        guard r.u16() == 0x0002 else { print("ARSC değil"); exit(1) }
        let headerSize = Int(r.u16())
        let tableSize = Int(r.u32())

        var pos = headerSize
        while pos + 8 <= bytes.count, pos < tableSize {
            var c = ByteReader(bytes: bytes, pos: pos)
            let chunkType = c.u16()
            let chunkHeaderSize = Int(c.u16())
            let chunkSize = Int(c.u32())
            guard chunkSize >= 8, pos + chunkSize <= bytes.count else { break }

            if chunkType == 0x0200 {
                // Paket başlığı: tip chunk'larını tara
                var inner = pos + chunkHeaderSize
                while inner + 8 <= pos + chunkSize {
                    var t = ByteReader(bytes: bytes, pos: inner)
                    let tType = t.u16()
                    let tHeaderSize = Int(t.u16())
                    let tSize = Int(t.u32())
                    guard tSize >= 8, inner + tSize <= bytes.count else { break }

                    if tType == 0x0201 {
                        var h = ByteReader(bytes: bytes, pos: inner + 8)
                        let tid = Int(h.u8())
                        let flags = h.u8()
                        _ = h.u16()
                        let entryCount = Int(h.u32())
                        let entriesStart = Int(h.u32())

                        if tid == typeId {
                            let offTable = inner + tHeaderSize
                            print("chunk @\(inner)  typeId=\(tid) flags=0x\(String(flags, radix: 16))")
                            print("  headerSize=\(tHeaderSize) chunkSize=\(tSize) entryCount=\(entryCount) entriesStart=\(entriesStart)")
                            print("  ofset tablosu @\(offTable)")

                            let mode = flags & 0x02 != 0 ? "u16 (*4)" : (flags & 0x01 != 0 ? "sparse (u16 çift, *4)" : "u32")
                            print("  biçem: \(mode)")
                            print("  ilk 8 ofset:")
                            for i in 0..<8 {
                                let p = offTable + i * 4
                                guard p + 4 <= bytes.count else { break }
                                let w = UInt32(bytes[p]) | (UInt32(bytes[p+1]) << 8)
                                    | (UInt32(bytes[p+2]) << 16) | (UInt32(bytes[p+3]) << 24)
                                let lo = UInt16(bytes[p]) | (UInt16(bytes[p+1]) << 8)
                                print("    [\(i)] u32=0x\(String(w, radix: 16))  u16=0x\(String(lo, radix: 16)) -> x4=\(Int(lo) * 4)")
                            }

                            let show = min(entryCount, entryId + 1)
                            if entryId < show {
                                // u32 yorumu
                                let p32 = offTable + entryId * 4
                                if p32 + 4 <= bytes.count {
                                    let o32 = Int(UInt32(bytes[p32]) | (UInt32(bytes[p32+1]) << 8)
                                                  | (UInt32(bytes[p32+2]) << 16) | (UInt32(bytes[p32+3]) << 24))
                                    print("  entry[\(entryId)] u32 ofset=\(o32)")
                                    hexDump(bytes, at: inner + entriesStart + o32, label: "u32 ofsetle girdi")
                                }
                                // u16 yorumu
                                let p16 = offTable + entryId * 2
                                if p16 + 2 <= bytes.count {
                                    let o16 = Int(UInt16(bytes[p16]) | (UInt16(bytes[p16+1]) << 8))
                                    print("  entry[\(entryId)] u16 raw=\(o16) -> x4=\(o16 * 4)")
                                    hexDump(bytes, at: inner + entriesStart + o16 * 4, label: "u16 x4 ofsetle girdi")
                                }
                            }
                            exit(0)
                        }
                    }
                    inner += tSize
                }
            }
            pos += chunkSize
        }
        print("typeId=\(typeId) bulunamadı")
        exit(1)
    }

    private static func hexDump(_ bytes: [UInt8], at offset: Int, label: String) {
        guard offset >= 0, offset + 32 <= bytes.count else {
            print("    \(label): sınırlar dışında (offset=\(offset), boyut=\(bytes.count))")
            return
        }
        let slice = bytes[offset..<(offset + 32)].map { String(format: "%02x", $0) }
        print("    \(label) @\(offset): \(slice.joined(separator: " "))")
    }

    // MARK: - Ekran önizleme boru hattı testi

    /// Yerleşik scrcpy istemcisini çalıştırıp video akışını doğrular.
    static func previewTest() -> Never {
        guard let adbPath = ADBService.locateADB() else {
            print("adb bulunamadı"); exit(1)
        }
        let adb = ADBService(adbPath: adbPath)
        guard let device = adb.listDevices().first(where: { $0.state.isControllable }) else {
            print("kontrol edilebilir cihaz yok"); exit(2)
        }
        guard let serverPath = ADBService.locateScrcpyServer() else {
            print("scrcpy-server bulunamadı"); exit(3)
        }

        print("Cihaz    : \(device.serial)")
        print("Server   : \(serverPath)")

        let client = ScrcpyClient()
        client.verbose = true
        let counter = FrameCounter()
        var lastFrame: CVImageBuffer?
        let frameLock = NSLock()
        client.onPixelBuffer = { buffer, _ in
            counter.increment()
            frameLock.lock()
            lastFrame = buffer
            frameLock.unlock()
        }
        client.onVideoSize = { size in
            print("Video boyutu: \(Int(size.width))x\(Int(size.height))")
        }
        client.onError = { print("HATA: \($0)") }

        print("Başlatılıyor…")
        let startSem = DispatchSemaphore(value: 0)
        var startOK = false
        client.start(adbPath: adbPath, serial: device.serial, serverLocalPath: serverPath) { ok, error in
            startOK = ok
            if !ok { print("Başlatılamadı: \(error ?? "bilinmeyen")") }
            startSem.signal()
        }
        _ = startSem.wait(timeout: .now() + 20)
        guard startOK else { exit(4) }

        print("El sıkışma bekleniyor…")
        Thread.sleep(forTimeInterval: 1.0)
        print("El sıkışma   : \(client.handshakeOK ? "OK" : "BAŞARISIZ")  hata: \(client.lastReadError.isEmpty ? "-" : client.lastReadError)")
        print("Cihaz adı    : \"\(client.meta.deviceName)\"  codec: 0x\(String(client.meta.codecID, radix: 16))")
        print("5 saniye akış okunuyor…")

        let t0 = Date()
        while Date().timeIntervalSince(t0) < 5 {
            Thread.sleep(forTimeInterval: 0.5)
            print("  … paket=\(client.statPackets) config=\(client.statConfigPackets) çerçeve=\(client.statFrames) biçimsiz=\(client.statNoFormat)")
        }

        let total = counter.value
        let fps = Double(total) / 5.0
        print("")
        print("Ham paket        : \(client.statPackets)")
        print("Config paketi    : \(client.statConfigPackets)")
        print("Sıkışık örnek    : \(client.statFrames)")
        print("Çözülmüş piksel  : \(counter.value)")
        print("Biçimsiz paket   : \(client.statNoFormat)")
        print("Ortalama FPS     : \(String(format: "%.1f", fps))")
        print("Oturum boyutu    : \(client.meta.sessionWidth)x\(client.meta.sessionHeight)")

        // Son kareyi PNG olarak yaz — görsel doğrulama için.
        frameLock.lock()
        let captured = lastFrame
        frameLock.unlock()
        if let captured {
            let ciImage = CIImage(cvPixelBuffer: captured)
            let ciContext = CIContext()
            if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                let rep = NSBitmapImageRep(cgImage: cgImage)
                if let png = rep.representation(using: .png, properties: [:]) {
                    let outPath = NSHomeDirectory() + "/.hermes/cache/scratch/preview_frame.png"
                    try? png.write(to: URL(fileURLWithPath: outPath))
                    print("Son kare PNG     : \(outPath)")
                }
            }
        }

        client.stop()

        let log = client.serverOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !log.isEmpty {
            print("")
            print("== sunucu çıktısı ==")
            print(String(log.suffix(1200)))
        }

        if total > 10 {
            print("")
            print("Sonuç: OK — video akışı çözüldü ve işlendi.")
            exit(0)
        } else {
            print("")
            print("Sonuç: BAŞARISIZ — yeterli paket alınamadı.")
            exit(5)
        }
    }

    // MARK: - Cihazdan

    static func fromDevice(serial: String? = nil) -> Never {
        guard let adbPath = ADBService.locateADB() else {
            print("adb bulunamadı")
            exit(1)
        }
        let adb = ADBService(adbPath: adbPath)

        let devices = adb.listDevices()
        guard let target = serial.map({ s in devices.first(where: { $0.serial == s }) })
                ?? devices.first(where: { $0.state.isControllable }) else {
            print("kontrol edilebilir cihaz yok")
            exit(2)
        }

        let locale = deviceLocale(adb: adb, serial: target.serial)
        print("Cihaz : \(target.serial)  (yerel ayar: \(locale ?? "varsayılan"))")
        print("")

        let apps = adb.listLaunchableApps(target.serial)
        print(pad("PAKET", 42) + "  " + pad("ETİKET", 28) + "  KAYNAK")
        print(String(repeating: "-", count: 100))

        var hit = 0
        for app in apps {
            let result = label(for: app.packageName, adb: adb, serial: target.serial, locale: locale)
            let label = result.label ?? "-"
            if result.label != nil { hit += 1 }
            print(pad(app.packageName, 42) + "  " + pad(label, 28) + "  " + result.source)
        }

        print("")
        print("Sonuç: \(hit)/\(apps.count) uygulama için gerçek ad bulundu.")
        exit(hit > 0 ? 0 : 3)
    }

    // MARK: - Tek paket

    static func label(for packageName: String,
                      adb: ADBService,
                      serial: String,
                      locale: String?) -> ApkLabelResult {
        // 1) APK yolu
        let pathResult = adb.apkPaths(serial: serial, packageName: packageName)
        guard let baseAPK = pathResult.first(where: { $0.hasSuffix("base.apk") }) ?? pathResult.first else {
            return ApkLabelResult(packageName: packageName, label: nil, source: "apk yok")
        }

        // 2) Manifest + resources.arsc
        guard let manifest = adb.extractEntry(serial: serial, apkPath: baseAPK, entry: "AndroidManifest.xml") else {
            return ApkLabelResult(packageName: packageName, label: nil, source: "manifest alınamadı")
        }

        let arsc = adb.extractEntry(serial: serial, apkPath: baseAPK, entry: "resources.arsc")

        // 3) Çöz
        var result = ApkLabel.resolve(packageName: packageName, manifest: manifest, arsc: arsc, locale: locale)
        if result.label == nil, pathResult.count > 1 {
            // Split APK'lerde de dene (ör. dil paketleri).
            for split in pathResult where split != baseAPK {
                guard let m = adb.extractEntry(serial: serial, apkPath: split, entry: "AndroidManifest.xml") else { continue }
                let a = adb.extractEntry(serial: serial, apkPath: split, entry: "resources.arsc")
                let r = ApkLabel.resolve(packageName: packageName, manifest: m, arsc: a, locale: locale)
                if r.label != nil {
                    result = ApkLabelResult(packageName: packageName, label: r.label, source: "split: " + r.source)
                    break
                }
            }
        }
        return result
    }

    static func deviceLocale(adb: ADBService, serial: String) -> String? {
        let props = adb.deviceProperties(serial)
        if let l = props["persist.sys.locale"], !l.isEmpty {
            // "tr-TR" -> "trTR" biçimindeki ARSC dil koduna yakınlaştır
            return normalizeLocale(l)
        }
        if let l = props["ro.product.locale"], !l.isEmpty {
            return normalizeLocale(l)
        }
        return nil
    }

    /// "tr-TR" / "tr_TR" -> "tr" (ARSC'de dil 2 harf, ülke "rXX" biçiminde).
    private static func normalizeLocale(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "_", with: "-")
        let parts = cleaned.split(separator: "-").map(String.init)
        guard let language = parts.first, language.count == 2 else { return cleaned }
        if parts.count >= 2, parts[1].count == 2 {
            return language + "r" + parts[1].uppercased()
        }
        return language
    }
}

// MARK: - Kare sayacı (test)

final class FrameCounter {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

// MARK: - ADB uzantısı: APK çıkarma

extension ADBService {

    /// `pm path <pkg>` çıktısındaki APK yolları.
    func apkPaths(serial: String, packageName: String) -> [String] {
        let result = shell(serial, ["pm", "path", packageName], timeout: 25)
        return result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("package:") }
            .map { String($0.dropFirst("package:".count)) }
    }

    /// APK içindeki bir girdiyi (`unzip -p`) ikili olarak çıkarır.
    func extractEntry(serial: String, apkPath: String, entry: String) -> Data? {
        let result = ProcessRunner.runData(adbPath,
                                           arguments: ["-s", serial, "exec-out",
                                                       "unzip", "-p", apkPath, entry],
                                           timeout: 60)
        guard result.exitCode == 0, !result.stdout.isEmpty else { return nil }
        return result.stdout
    }
}
