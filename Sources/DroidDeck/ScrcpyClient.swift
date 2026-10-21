import Foundation
import CoreMedia

/// scrcpy protokolü istemcisi (v5.x). Video akışını alır, kontrol mesajlarını gönderir.
///
/// Kablolar (hepsi big-endian):
///   video soketi:
///     [1 dummy][64 cihaz adı][4 codec id]
///     tekrarlayan paketler:
///       12 bayt çerçeve başlığı = 8 bayt (u64: bayraklar + PTS) + 4 bayt boyut
///         bay63 = media paketi (0), bay62 = C (config), bay61 = K (keyframe)
///         MSB=1 ise OTURUM paketi (12 bayt, payload yok; [flags][width][height])
///       ardından payload (Annex-B H.264)
///   kontrol soketi: [1 tip][payload...]
final class ScrcpyClient {

    struct VideoMeta {
        var deviceName: String = ""
        var codecID: UInt32 = 0
        var sessionWidth: Int = 0
        var sessionHeight: Int = 0
    }

    // MARK: - Durum
    //
    // Bu alanlar okuyucu iş parçacığından yazılır ve ana/CLI iş parçacığından
    // okunur. Kilitsiz erişim Swift'te tanımsız davranıştır (TSan raporlar);
    // erişimler `stateLock` altına alınır.

    private var _meta = VideoMeta()
    private var _isRunning = false
    private var _statPackets = 0
    private var _statConfigPackets = 0
    private var _statFrames = 0
    private var _statNoFormat = 0
    private var _handshakeOK = false
    private var _lastReadError = ""

    var meta: VideoMeta {
        get { locked { _meta } }
        set { locked { _meta = newValue } }
    }
    var isRunning: Bool {
        get { locked { _isRunning } }
        set { locked { _isRunning = newValue } }
    }
    var statPackets: Int {
        get { locked { _statPackets } }
        set { locked { _statPackets = newValue } }
    }
    var statConfigPackets: Int {
        get { locked { _statConfigPackets } }
        set { locked { _statConfigPackets = newValue } }
    }
    var statFrames: Int {
        get { locked { _statFrames } }
        set { locked { _statFrames = newValue } }
    }
    var statNoFormat: Int {
        get { locked { _statNoFormat } }
        set { locked { _statNoFormat = newValue } }
    }
    var handshakeOK: Bool {
        get { locked { _handshakeOK } }
        set { locked { _handshakeOK = newValue } }
    }
    var lastReadError: String {
        get { locked { _lastReadError } }
        set { locked { _lastReadError = newValue } }
    }

    /// Paylaşılan duruma erişimi serileştirir.
    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// Her çözülmüş/ham paket için (CMSampleBuffer olarak) çağrılır.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// Çözülmüş piksel tamponları (VideoToolbox).
    var onPixelBuffer: ((CVImageBuffer, CMTime) -> Void)? {
        didSet { decoder.onFrame = onPixelBuffer }
    }
    var onError: ((String) -> Void)?
    var onStopped: (() -> Void)?
    var onVideoSize: ((CGSize) -> Void)?

    private var videoFD: Int32 = -1
    private var controlFD: Int32 = -1
    private var serverProcess: Process?
    private var readerThread: Thread?
    private let writeLock = NSLock()
    private var running = false
    private var serverLogBox: LogBox?
    /// Sunucu sürecinin ham çıktısı (tanılama için).
    var serverOutput: String { serverLogBox?.text ?? "" }

    /// Temizlikte cihaza erişmek için saklanır.
    private var boundADBPath: String?
    private var boundSerial: String?
    /// Kurulan `adb forward` portu. Temizlikte MUTLAKA kaldırılmalı —
    /// aksi halde her oturum geride `localabstract:scrcpy` yönlendirmesi
    /// bırakır, bunlar birikir ve yeni oturumlar ÖLÜ bir yönlendirmeye
    /// bağlanır (siyah ekran / takılma). Bizzat yaşandı: 8 kayit birikmişti.
    private var boundForwardPort: Int32 = 0
    private let fdLock = NSLock()
    /// `formatDesc` / `serverProcess` gibi okuyucu iş parçacığı ile ana iş
    /// parçacığı arasında paylaşılan CF/süreç durumunu korur. Bu alanlarda
    /// eşzamanlı okuma-yazma CF referans sayacı yarışıdır ve durdurma anında
    /// crash'e yol açabilir.
    private let stateLock = NSLock()
    /// `stop()` çağrıldığında kurulur; devam eden `boot()`'u durdurur.
    /// Aksi halde kullanıcı durdurmuşken başlatma tamamlanır ve cihazda
    /// yetim bir encoder kalır.
    private var cancelled = false
    /// Kontrol akışının senkronu bozulduğunda (kısmi yazım) kurulur.
    /// Sonraki mesajlar gönderilmez — sahte tuş/dokunma yorumlamasını önler.
    private var controlBroken = false

    private var formatDesc: CMVideoFormatDescription?
    private let decoder = VideoDecoder()
    private var pendingWidth = 0
    private var pendingHeight = 0

    /// Tanılama çıktıları.
    var verbose = false
    private func log(_ message: String) {
        if verbose { print("[scrcpy] \(message)") }
    }

    // MARK: - Başlatma

    func start(adbPath: String, serial: String, serverLocalPath: String,
               maxSize: Int = 1280, maxFPS: Int = 30, bitRate: Int = 2_000_000,
               completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                try boot(adbPath: adbPath,
                         serial: serial,
                         serverLocalPath: serverLocalPath,
                         maxSize: maxSize,
                         maxFPS: maxFPS,
                         bitRate: bitRate)
                completion(true, nil)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                completion(false, message)
            }
        }
    }

    private enum BootError: LocalizedError {
        case serverMissing(String)
        case forwardFailed(String)
        case connectFailed(String)
        case handshakeFailed(String)
        case pushFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .serverMissing(let s): return "scrcpy-server bulunamadı: \(s)"
            case .forwardFailed(let s): return "adb forward başarısız: \(s)"
            case .connectFailed(let s): return "Sokete bağlanılamadı: \(s)"
            case .handshakeFailed(let s): return "El sıkışma başarısız: \(s)"
            case .pushFailed(let s): return "scrcpy-server cihaza yüklenemedi: \(s)"
            case .cancelled: return "İptal edildi"
            }
        }
    }

    private func boot(adbPath: String, serial: String, serverLocalPath: String,
                      maxSize: Int, maxFPS: Int, bitRate: Int) throws {
        boundADBPath = adbPath
        boundSerial = serial
        cancelled = false
        controlBroken = false

        guard FileManager.default.fileExists(atPath: serverLocalPath) else {
            throw BootError.serverMissing(serverLocalPath)
        }

        let remotePath = "/data/local/tmp/scrcpy-server.jar"

        // 0) Eski sunucu süreçlerini temizle.
        //
        // ÖNEMLİ SINIR: `localabstract:scrcpy` soketi cihaz başına TEK'tir.
        // Yani aynı anda yalnızca BİR scrcpy oturumu çalışabilir — küçük
        // önizleme ile büyük ekran (harici scrcpy) yan yana olamaz. Bu yüzden
        // burada yalnızca kendi ölü oturumumuzun kalıntılarını temizliyoruz;
        // canlı bir oturum varsa uygulama bunu bilerek sonlandırmalı ve
        // kullanıcıya söylemeli (bkz. DeviceStore.startPreview).
        // Seri kuyruktan: teardown'un pkill'i ile çakışmasın.
        Self.serverOpsQueue.sync {
            _ = run(adbPath, ["-s", serial, "shell", "pkill -f scrcpy-server"])
        }
        usleep(400_000)

        // 1) Sunucuyu cihaza it. Sonuç YUTULMAMALI: push başarısız olursa sunucu
        //    eski/eksik jar ile başlar ve kullanıcı gerçek neden yerine
        //    'El sıkışma başarısız' hatası görür.
        let push = run(adbPath, ["-s", serial, "push", serverLocalPath, remotePath])
        guard push.succeeded else {
            throw BootError.pushFailed(push.combined)
        }

        // 2) Yerel port bul + tünel kur.
        let port = try freeLocalPort()
        log("yerel port: \(port)")
        // YALNIZCA kendi kaydımızı temizle. Başka oturumların (örn. harici
        // scrcpy penceresi) yönlendirmelerine dokunmak onları koparır —
        // yanlışlıkla yaptım, kullanıcı büyük ekranını kaybediyordu.
        _ = run(adbPath, ["-s", serial, "forward", "--remove", "tcp:\(port)"])
        let fwd = run(adbPath, ["-s", serial, "forward", "tcp:\(port)", "localabstract:scrcpy"])
        guard fwd.exitCode == 0 else { throw BootError.forwardFailed(fwd.combined) }
        boundForwardPort = Int32(port)
        log("forward kuruldu")

        // 3) Sunucuyu başlat (arka planda).
        let args = [
            "log_level=info",
            "tunnel_forward=true",
            "audio=false",
            "control=true",
            "video=true",
            "cleanup=true",
            "send_device_meta=true",
            "send_dummy_byte=true",
            "send_stream_meta=true",
            "send_frame_meta=true",
            "video_source=display",
            "video_codec=h264",
            "display_id=0",
            "max_size=\(maxSize)",
            "max_fps=\(maxFPS)",
            "video_bit_rate=\(bitRate)",
        ]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", serial, "shell",
                             "CLASSPATH=\(remotePath)", "app_process", "/",
                             "com.genymobile.scrcpy.Server", "5.0.1"] + args
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        // Aynı seri kuyruktan başlat: teardown'un gecikmiş pkill'i bu başlatmayı
        // öldüremesin diye.
        try Self.serverOpsQueue.sync {
            try process.run()
        }
        stateLock.lock()
        serverProcess = process
        stateLock.unlock()
        log("sunucu başlatıldı (pid \(process.processIdentifier))")

        // Sunucu `localabstract:scrcpy` soketini açana kadar bekle.
        // `adb forward` yerel connect()i optimistçe kabul eder; soket hazır
        // değilse adb bağlantıyı kapatır ve okuma anında EOF alır.
        usleep(2_000_000)

        // Sunucu çıktısını arka planda topla (tanılama için).
        let logBox = LogBox()
        serverLogBox = logBox
        DispatchQueue.global(qos: .utility).async {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            logBox.append(String(decoding: data, as: UTF8.self))
        }

        // 4-6) Soketler + el sıkışma. Herhangi biri başarısız olursa
        // cihaz tarafındaki encoder'ı da kesmeliyiz — aksi halde boşuna
        // ekran kodlamaya devam eder (pil ve ısınma yükü).
        // adb forward yerel connect'i optimistçe kabul edip sunucu henüz hazır
        // değilse anında kapatır: arıza modu connect() hatası DEĞİL, el sıkışmada
        // EOF'tur. Yeniden denemeyi doğru katmanda yapmak gerekir — connect + el
        // sıkışma birlikte TEK bir denemedir. Soketlere okuma zaman aşımı da konur:
        // sunucu açılıp başlangıç baytlarını göndermezse boot() sonsuz bloke olur.
        var lastBootError: Error?
        var attempt = 0
        while attempt < 4 {
            attempt += 1
            try checkCancelled(adbPath: adbPath, serial: serial)

            do {
                let fd = try connectWithRetry(port: port, attempts: 40, delayMS: 150)
                try checkCancelled(adbPath: adbPath, serial: serial)
                Self.setReadTimeout(fd, seconds: 5)
                videoFD = fd
                log("video soketi fd=\(fd)")

                let cfd = try connectWithRetry(port: port, attempts: 40, delayMS: 150)
                try checkCancelled(adbPath: adbPath, serial: serial)
                Self.setReadTimeout(cfd, seconds: 5)
                controlFD = cfd
                log("kontrol soketi fd=\(cfd)")

                guard readHandshake() else {
                    throw BootError.handshakeFailed("video soketi beklenen başlangıç baytlarını göndermedi")
                }
                // El sıkışmadan sonra okuma zaman aşımını KALDIR: durgun ekranda
                // kare gelmeyebilir ve akış zaman aşımıyla kesilmemeli.
                Self.setReadTimeout(fd, seconds: 0)
                log("el sıkışma tamam (deneme \(attempt))")
                lastBootError = nil
                break
            } catch {
                // ÖNEMLİ: burada TAM teardown YAPILMAZ. Tam teardown hem
                // `adb forward` kaydını siler hem de sunucuyu öldürür — o zaman
                // 2-4. denemeler forward'sız porta bağlanmaya çalışır ve her
                // biri ~6 sn ECONNREFUSED ile bekler. Yani yeniden deneme hiçbir
                // koşulda başarılı olamazdı; sadece 20+ sn sessizlik üretirdi.
                // Sadece soketleri kapat; forward + sunucu ayakta kalsın.
                lastBootError = error
                closeSocketsOnly()
                if attempt < 4 { usleep(700_000) }
            }
        }

        if let lastBootError {
            // Gerçekten bitti — şimdi tam temizlik.
            teardown(adbPath: adbPath, serial: serial)
            throw lastBootError
        }

        // Kullanıcı tam bu sırada durdurmuş olabilir.
        try checkCancelled(adbPath: adbPath, serial: serial)

        running = true
        isRunning = true

        // 7) Okuma iş parçacığı.
        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "scrcpy.video"
        thread.qualityOfService = .userInitiated
        readerThread = thread
        thread.start()
    }

    private func connectWithRetry(port: Int, attempts: Int, delayMS: Int) throws -> Int32 {
        var lastErrno: Int32 = 0
        for _ in 0..<attempts {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw BootError.connectFailed("socket()") }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let ok = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if ok == 0 {
                // Küçük yuvalar (Nagle) gecikmeyi düşürür.
                var nodelay: Int32 = 1
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))
                return fd
            }
            lastErrno = errno
            close(fd)
            usleep(useconds_t(delayMS * 1000))
        }
        throw BootError.connectFailed("errno=\(lastErrno)")
    }

    private func freeLocalPort() throws -> Int {
        // Basit: adb'nin kabul edeceği serbest bir port bul.
        for port in 27183..<27250 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(fd)
            if bound == 0 { return port }
        }
        return 27183
    }

    // MARK: - Okuma döngüsü

    private func readLoop() {
        handshakeOK = true

        while running {
            var header = [UInt8](repeating: 0, count: 12)
            guard readExact(header.count, into: &header) else {
                lastReadError = "başlık okunamadı"
                break
            }

            let flags = UInt64(header[0]) << 56 | UInt64(header[1]) << 48
                | UInt64(header[2]) << 40 | UInt64(header[3]) << 32
                | UInt64(header[4]) << 24 | UInt64(header[5]) << 16
                | UInt64(header[6]) << 8 | UInt64(header[7])

            // MSB=1 -> oturum paketi (payload yok)
            if flags & 0x8000_0000_0000_0000 != 0 {
                let w = Int(header[4]) << 24 | Int(header[5]) << 16 | Int(header[6]) << 8 | Int(header[7])
                let h = Int(header[8]) << 24 | Int(header[9]) << 16 | Int(header[10]) << 8 | Int(header[11])
                if w > 0 && h > 0 {
                    meta.sessionWidth = w
                    meta.sessionHeight = h
                    DispatchQueue.main.async { [weak self] in
                        self?.onVideoSize?(CGSize(width: w, height: h))
                    }
                }
                continue
            }

            let isConfig = (flags & (1 << 62)) != 0
            // Alt 61 bit = PTS (mikrosaniye)
            let ptsMicros = flags & 0x1FFF_FFFF_FFFF_FFFF
            let size = Int(header[8]) << 24 | Int(header[9]) << 16 | Int(header[10]) << 8 | Int(header[11])
            // Geçersiz boyutta payload OKUNMADAN devam etmek akışı kalıcı olarak
            // kaydırır: bundan sonraki her 12 baytlık pencere paket başlığı sanılır
            // ve ya sonsuz boş döngü ya da megabaytlık sahte okumalar başlar.
            // Protokol hatası = oturum sonu; finish() temizliği yapar.
            guard size > 0, size < 32 * 1024 * 1024 else {
                lastReadError = "geçersiz paket boyutu: \(size)"
                break
            }

            var payload = [UInt8](repeating: 0, count: size)
            guard readExact(size, into: &payload) else { break }

            handlePacket(Data(payload), isConfig: isConfig, ptsMicros: ptsMicros)
        }

        finish()
    }

    /// Soket okumasına zaman aşımı koyar: sunucu açılıp başlangıç baytlarını
    /// göndermezse `boot()` süresiz bloke olur ve completion hiç çağrılmaz.
    private static func setReadTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval()
        tv.tv_sec = seconds
        tv.tv_usec = 0
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func readHandshake() -> Bool {
        var dummy = [UInt8](repeating: 0, count: 1)
        guard readExact(1, into: &dummy) else { log("dummy baytı okunamadı"); return false }
        log("dummy=0x\(String(dummy[0], radix: 16))")

        var nameBytes = [UInt8](repeating: 0, count: 64)
        guard readExact(64, into: &nameBytes) else { log("cihaz adı okunamadı"); return false }
        if let end = nameBytes.firstIndex(of: 0) {
            meta.deviceName = String(decoding: nameBytes[0..<end], as: UTF8.self)
        } else {
            meta.deviceName = String(decoding: nameBytes, as: UTF8.self)
        }
        log("cihaz adı=\"\(meta.deviceName)\"")

        var codecBytes = [UInt8](repeating: 0, count: 4)
        guard readExact(4, into: &codecBytes) else { log("codec okunamadı"); return false }
        meta.codecID = UInt32(codecBytes[0]) << 24 | UInt32(codecBytes[1]) << 16
            | UInt32(codecBytes[2]) << 8 | UInt32(codecBytes[3])
        log("codec=0x\(String(meta.codecID, radix: 16))")

        return true
    }

    /// `count` baytı tam olarak okur.
    ///
    /// NEDEN `dup`: eskiden `fdLock` BLOK EDEN okuma boyunca tutuluyordu ve
    /// `teardown()` fd'yi kilitsiz okuyordu. teardown taze yazılmış fd'yi
    /// göremezse (`-1`) shutdown atlanır → `readExact` kilidi tutarak sonsuz
    /// `read()`'te kalır → `teardown` kilit bekler → TÜM UYGULAMA donardı.
    ///
    /// Şimdi okuma kendi kopyası üzerinde yapılır; `fdLock` yalnızca fd'yi
    /// kopyalarken tutulur. `shutdown()` soket düzeyinde çalıştığı için kopyayı
    /// da uyandırır.
    private func readExact(_ count: Int, into array: inout [UInt8]) -> Bool {
        array.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress else { return false }

            fdLock.lock()
            let fd = videoFD >= 0 ? dup(videoFD) : -1
            fdLock.unlock()
            guard fd >= 0 else { return false }
            defer { close(fd) }

            var got = 0
            while got < count {
                let n = Darwin.read(fd, base.advanced(by: got), count - got)
                if n < 0 {
                    if errno == EINTR { continue }   // sinyalle kesildi: yeniden dene
                    return false
                }
                if n == 0 { return false }           // EOF — sunucu kapattı
                got += n
            }
            return true
        }
    }

    // MARK: - Paket işleme

    private func handlePacket(_ data: Data, isConfig: Bool, ptsMicros: UInt64) {
        statPackets += 1
        let nals = Self.splitAnnexB(data)

        if isConfig {
            statConfigPackets += 1
            var sps: Data?
            var pps: Data?
            for nal in nals {
                guard let first = nal.first else { continue }
                switch first & 0x1F {
                case 7: sps = nal
                case 8: pps = nal
                default: break
                }
            }
            if let sps, let pps {
                rebuildFormatDescription(sps: sps, pps: pps)
            }
            return
        }

        // formatDesc okuyucu iş parçacığından, teardown ana iş parçacığından
        // yazar. Kilitsiz okuma/yazma CF referans yarışıdır; yerel kopya al.
        stateLock.lock()
        let formatDesc = self.formatDesc
        stateLock.unlock()

        guard let formatDesc else {
            statNoFormat += 1
            return
        }
        let frameNals = nals.filter { nal in
            guard let first = nal.first else { return false }
            let type = first & 0x1F
            return type != 7 && type != 8 && type != 9   // SPS/PPS/AUD atla
        }
        guard !frameNals.isEmpty else { return }

        // Uzunluk önekli (AVCC) blok tamponu kur.
        var total = 0
        for nal in frameNals { total += 4 + nal.count }

        var dataBytes = [UInt8](repeating: 0, count: total)
        var offset = 0
        for nal in frameNals {
            let len = UInt32(nal.count)
            dataBytes[offset] = UInt8((len >> 24) & 0xFF)
            dataBytes[offset + 1] = UInt8((len >> 16) & 0xFF)
            dataBytes[offset + 2] = UInt8((len >> 8) & 0xFF)
            dataBytes[offset + 3] = UInt8(len & 0xFF)
            offset += 4
            dataBytes.withUnsafeMutableBufferPointer { buf in
                nal.copyBytes(to: buf.baseAddress!.advanced(by: offset), count: nal.count)
            }
            offset += nal.count
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                        memoryBlock: nil,
                                                        blockLength: total,
                                                        blockAllocator: kCFAllocatorDefault,
                                                        customBlockSource: nil,
                                                        offsetToData: 0,
                                                        dataLength: total,
                                                        flags: 0,
                                                        blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer else { return }

        status = dataBytes.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base,
                                                 blockBuffer: blockBuffer,
                                                 offsetIntoDestination: 0,
                                                 dataLength: total)
        }
        guard status == noErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = total

        // Zaman damgası ZORUNLU — AVSampleBufferDisplayLayer zamansız örnekleri göstermez.
        let pts = CMTime(value: CMTimeValue(ptsMicros), timescale: 1_000_000)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)

        let sampleStatus = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                                     dataBuffer: blockBuffer,
                                                     formatDescription: formatDesc,
                                                     sampleCount: 1,
                                                     sampleTimingEntryCount: 1,
                                                     sampleTimingArray: &timing,
                                                     sampleSizeEntryCount: 1,
                                                     sampleSizeArray: &sampleSize,
                                                     sampleBufferOut: &sampleBuffer)
        guard sampleStatus == noErr, let sampleBuffer else { return }

        statFrames += 1
        // Okuyucu iş parçacığında çağrılır (yüksek kare hızında ana iş parçacığını tıkamaz).
        onSampleBuffer?(sampleBuffer)
        decoder.decode(sampleBuffer)
    }

    private func rebuildFormatDescription(sps: Data, pps: Data) {
        var desc: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsRaw -> OSStatus in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                guard let spsBase = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return -1
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { ptrBuf in
                    sizes.withUnsafeBufferPointer { sizeBuf in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrBuf.baseAddress!,
                            parameterSetSizes: sizeBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &desc)
                    }
                }
            }
        }
        guard status == noErr, let desc else {
            DispatchQueue.main.async { [weak self] in
                self?.onError?("Biçim açıklaması oluşturulamadı (OSStatus=\(status))")
            }
            return
        }

        stateLock.lock()
        formatDesc = desc
        stateLock.unlock()
        decoder.setFormat(desc)
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        meta.sessionWidth = Int(dims.width)
        meta.sessionHeight = Int(dims.height)
        DispatchQueue.main.async { [weak self] in
            self?.onVideoSize?(CGSize(width: Int(dims.width), height: Int(dims.height)))
        }
    }

    /// Annex-B akışını NAL birimlerine böler (başlangıç kodları atılır).
    static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var result: [Data] = []
        var i = 0
        var start = -1

        func isStartCode(_ idx: Int) -> Int {
            // 4 baytlık başlangıç kodunu tercih et
            if idx + 4 <= bytes.count,
               bytes[idx] == 0, bytes[idx + 1] == 0, bytes[idx + 2] == 0, bytes[idx + 3] == 1 {
                return 4
            }
            if idx + 3 <= bytes.count,
               bytes[idx] == 0, bytes[idx + 1] == 0, bytes[idx + 2] == 1 {
                return 3
            }
            return 0
        }

        while i < bytes.count {
            let sc = isStartCode(i)
            if sc > 0 {
                if start >= 0 {
                    result.append(Data(bytes[start..<i]))
                }
                i += sc
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < bytes.count {
            result.append(Data(bytes[start..<bytes.count]))
        }
        return result
    }

    // MARK: - Kontrol mesajları

    private func send(_ bytes: [UInt8]) {
        writeLock.lock()
        defer { writeLock.unlock() }

        // Yazım fdLock ALTINDA: teardown()'ın close()'i bu yazım bitene dek
        // bekler, fd numarasının yeniden kullanımı ihtimali dışarıda kalır.
        fdLock.lock()
        defer { fdLock.unlock() }
        guard controlFD >= 0, !controlBroken else { return }

        var sent = 0
        bytes.withUnsafeBufferPointer { buf in
            while sent < bytes.count {
                let n = Darwin.write(controlFD, buf.baseAddress!.advanced(by: sent), bytes.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }   // sinyalle kesildi: yeniden dene
                    break
                }
                if n == 0 { break }
                sent += n
            }
        }

        // Kısmi gönderim kontrol akışının senkronunu kalıcı olarak bozar:
        // sonraki mesajın baytları yarım mesajın payload'ı sanılır (sahte
        // tuş/dokunma yorumlaması). Bağlantıyı bırak.
        if sent != bytes.count {
            controlBroken = true
            shutdown(controlFD, SHUT_RDWR)
        }
    }

    private static func u16fp(_ value: Float) -> UInt16 {
        UInt16(max(0, min(1, value)) * Float(UInt16.max))
    }

    private static func i16fp(_ value: Float) -> Int16 {
        Int16(max(-1, min(1, value)) * Float(Int16.max))
    }

    // ACTION_* (android.view.MotionEvent)
    static let actionDown: UInt8 = 0
    static let actionUp: UInt8 = 1
    static let actionMove: UInt8 = 2
    static let pointerIDMouse: UInt64 = UInt64.max

    /// Dokunma/tıklama. x, y: video koordinatları; width/height: video boyutu.
    func sendTouch(action: UInt8, x: Int, y: Int, width: Int, height: Int,
                   pressure: Float = 1.0, actionButton: UInt32 = 0, buttons: UInt32 = 0) {
        var b: [UInt8] = [2, action]                       // tip=2, aksiyon
        b.append(contentsOf: Self.be64(Self.pointerIDMouse))
        b.append(contentsOf: Self.be32(UInt32(max(0, x))))
        b.append(contentsOf: Self.be32(UInt32(max(0, y))))
        b.append(contentsOf: Self.be16(UInt16(max(0, min(65535, width)))))
        b.append(contentsOf: Self.be16(UInt16(max(0, min(65535, height)))))
        b.append(contentsOf: Self.be16(Self.u16fp(pressure)))
        b.append(contentsOf: Self.be32(actionButton))
        b.append(contentsOf: Self.be32(buttons))
        send(b)   // 32 bayt
    }

    /// Kaydırma (tekerlek).
    func sendScroll(x: Int, y: Int, width: Int, height: Int, hScroll: Float, vScroll: Float) {
        var b: [UInt8] = [3]
        b.append(contentsOf: Self.be32(UInt32(max(0, x))))
        b.append(contentsOf: Self.be32(UInt32(max(0, y))))
        b.append(contentsOf: Self.be16(UInt16(max(0, min(65535, width)))))
        b.append(contentsOf: Self.be16(UInt16(max(0, min(65535, height)))))
        b.append(contentsOf: Self.be16(UInt16(bitPattern: Self.i16fp(hScroll / 16))))
        b.append(contentsOf: Self.be16(UInt16(bitPattern: Self.i16fp(vScroll / 16))))
        b.append(contentsOf: Self.be32(0))
        send(b)   // 21 bayt
    }

    /// Tuş basımı.
    func sendKey(action: UInt8, keycode: UInt32, repeatCount: UInt32 = 0, metaState: UInt32 = 0) {
        var b: [UInt8] = [0, action]
        b.append(contentsOf: Self.be32(keycode))
        b.append(contentsOf: Self.be32(repeatCount))
        b.append(contentsOf: Self.be32(metaState))
        send(b)   // 14 bayt
    }

    /// Metin yazma.
    func sendText(_ text: String) {
        let utf8 = Array(text.utf8)
        guard !utf8.isEmpty else { return }
        var b: [UInt8] = [1]
        b.append(contentsOf: Self.be32(UInt32(utf8.count)))
        b.append(contentsOf: utf8)
        send(b)
    }

    /// Geri tuşu / ekranı aç.
    func sendBackOrScreenOn(action: UInt8) {
        send([4, action])
    }

    /// Ekran gücünü değiştir.
    func sendDisplayPower(on: Bool) {
        send([10, on ? 1 : 0])
    }

    private static func be16(_ v: UInt16) -> [UInt8] {
        [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    private static func be64(_ v: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((v >> (56 - UInt64($0) * 8)) & 0xFF) }
    }

    // MARK: - Durdurma

    /// Yeniden deneme arasında yalnızca soketleri kapatır.
    ///
    /// `teardown()`'tan farkı: `adb forward` kaydına ve cihazdaki sunucuya
    /// DOKUNMAZ. Böylece sonraki deneme aynı porta tekrar bağlanabilir.
    private func closeSocketsOnly() {
        if controlFD >= 0 { shutdown(controlFD, SHUT_RDWR) }
        if videoFD >= 0 { shutdown(videoFD, SHUT_RDWR) }

        fdLock.lock()
        if controlFD >= 0 {
            close(controlFD)
            controlFD = -1
        }
        if videoFD >= 0 {
            close(videoFD)
            videoFD = -1
        }
        fdLock.unlock()
    }

    /// Cihaz tarafındaki sunucu işlemleri için SERİ kuyruk.
    ///
    /// NEDEN: `teardown()`'taki `pkill -f scrcpy-server` asenkron çalışıyordu.
    /// adb meşgulken gecikirse, YENİ oturumun sunucusu başladıktan SONRA çalışır
    /// ve kalıp onu öldürürdü → el sıkışma EOF, akışın ortasında kopma, siyah
    /// ekran. (Belirti: "bazen çalışıyor, bazen siyah.") Artık pkill ve sunucu
    /// başlatma aynı kuyruktan geçer; biri bitmeden diğeri başlamaz.
    private static let serverOpsQueue = DispatchQueue(label: "droiddeck.scrcpy.serverops")

    /// Soketleri, süreçleri VE cihaz tarafındaki sunucuyu temizler.
    ///
    /// Başarısız başlatmalarda da çağrılmalıdır: aksi halde `scrcpy-server`
    /// cihazda kalmaya devam eder ve ekranı boş yere kodlar (pil/ısınma yükü).
    private func teardown(adbPath: String?, serial: String?) {
        // 1) shutdown() KİLİT ALMADAN. readExact()/send() fdLock'u tutup syscall'da
        //    bloke olmuş olabilir; kilit altında shutdown çağırırsak kilit hiç
        //    bırakılmazdı (deadlock). shutdown bloke okumayı anında bitirir.
        if controlFD >= 0 { shutdown(controlFD, SHUT_RDWR) }
        if videoFD >= 0 { shutdown(videoFD, SHUT_RDWR) }

        // 2) Şimdi kilit altında kapat. Yukarıdaki shutdown okuyucuyu
        //    uyandırdığı için readExact/send kısa sürede kilidi bırakır ve
        //    close() onların syscall'ı ile ÇAKIŞMAZ. Böylece fd numarasının
        //    kapanıp başka bir kaynakça (örn. adb pipe'ı) tarafından yeniden
        //    kullanılması ve yanlış fd'ye okuma/yazma ihtimali ortadan kalkar.
        fdLock.lock()
        if controlFD >= 0 {
            close(controlFD)
            controlFD = -1
        }
        if videoFD >= 0 {
            close(videoFD)
            videoFD = -1
        }
        fdLock.unlock()

        // Kendi kurduğumuz `adb forward` kaydını da kaldır. Bunu yapmazsak
        // her oturum geride ölü bir yönlendirme bırakır ve sonraki oturumlar
        // yanlış porta bağlanır (siyah ekran / takılma).
        if boundForwardPort > 0, let adbPath, let serial {
            _ = run(adbPath, ["-s", serial, "forward", "--remove", "tcp:\(boundForwardPort)"])
            boundForwardPort = 0
        }

        // Süreç nesnesi de okuyucu/ana iş parçacıkları arasında paylaşılır.
        stateLock.lock()
        let process = serverProcess
        serverProcess = nil
        stateLock.unlock()

        if let process, process.isRunning {
            process.terminate()
        }

        // Cihaz tarafındaki sunucuyu kes.
        //
        // SERİ KUYRUĞA alınır (global değil): aksi halde gecikmiş pkill yeni
        // oturumun sunucusunu öldürebilir. `async` olduğu için arayüz bloke
        // olmaz, ama sıradaki sunucu başlatma bu pkill'i bekler.
        if let adbPath, let serial {
            Self.serverOpsQueue.async {
                _ = ProcessRunner.run(adbPath,
                                      arguments: ["-s", serial, "shell", "pkill", "-f", "scrcpy-server"],
                                      timeout: 15)
            }
        }

        stateLock.lock()
        formatDesc = nil
        stateLock.unlock()
        decoder.invalidate()
    }

    func stop() {
        cancelled = true
        running = false
        isRunning = false
        teardown(adbPath: boundADBPath, serial: boundSerial)
    }

    /// `boot()` uzun adımlar arasında bunu çağırır; kullanıcı durdurduysa
    /// başlatmayı bırakır ve cihaz tarafını temizler.
    private func checkCancelled(adbPath: String, serial: String) throws {
        if cancelled {
            teardown(adbPath: adbPath, serial: serial)
            throw BootError.cancelled
        }
    }

    private func finish() {
        let wasRunning = isRunning
        running = false
        isRunning = false
        teardown(adbPath: boundADBPath, serial: boundSerial)

        DispatchQueue.main.async { [weak self] in
            if wasRunning { self?.onStopped?() }
        }
    }

    // MARK: - Yardımcı

    private func run(_ executable: String, _ args: [String]) -> CommandResult {
        ProcessRunner.run(executable, arguments: args, timeout: 60)
    }
}
