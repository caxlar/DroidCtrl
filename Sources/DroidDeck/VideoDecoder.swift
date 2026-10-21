import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// H.264 örnek tamponlarını `VTDecompressionSession` ile piksele çevirir.
final class VideoDecoder {

    private final class Context {
        let handler: (CVImageBuffer, CMTime) -> Void
        init(_ handler: @escaping (CVImageBuffer, CMTime) -> Void) { self.handler = handler }
    }

    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private var context: Context?
    private var callbackRecord: VTDecompressionOutputCallbackRecord?
    /// `session` / `formatDesc` / `onFrame` erişimini korur: `decode()`
    /// okuyucu iş parçacığından, `invalidate()` ana iş parçacığından çağrılır.
    /// Reküransiyel: DecodeFrame senkron callback verirse `onFrame` aynı
    /// iş parçacığından kilidi tekrar ister.
    private let lock = NSRecursiveLock()

    /// Çözülmüş her kare için çağrılır (VideoToolbox iş parçacığında).
    var onFrame: ((CVImageBuffer, CMTime) -> Void)? {
        // VideoToolbox callback iş parçacığından okunur, ana iş parçacığından
        // yazılır. Optional closure iki kelimelik değerdir; kilitsiz
        // okuma/yazma 'torn' değere ve crash'e yol açabilir.
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onFrame
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _onFrame = newValue
        }
    }
    private var _onFrame: ((CVImageBuffer, CMTime) -> Void)?

    private static let callback: VTDecompressionOutputCallback = {
        refcon, _, status, _, imageBuffer, pts, _ in
        guard status == noErr, let imageBuffer, let refcon else { return }
        let context = Unmanaged<Context>.fromOpaque(refcon).takeUnretainedValue()
        context.handler(imageBuffer, pts)
    }

    init() {
        let context = Context { [weak self] buffer, pts in
            self?.onFrame?(buffer, pts)
        }
        self.context = context

        var record = VTDecompressionOutputCallbackRecord()
        record.decompressionOutputCallback = Self.callback
        record.decompressionOutputRefCon = Unmanaged.passUnretained(context).toOpaque()
        callbackRecord = record
    }

    /// Biçim açıklamasını ayarlar; değişirse oturumu yeniden kurar.
    func setFormat(_ desc: CMVideoFormatDescription) {
        if let current = formatDesc,
           CMFormatDescriptionEqual(current, otherFormatDescription: desc) {
            return
        }

        invalidateSession()
        formatDesc = desc

        guard var record = callbackRecord else { return }
        var newSession: VTDecompressionSession?
        let status = withUnsafePointer(to: &record) { recordPtr -> OSStatus in
            VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                         formatDescription: desc,
                                         decoderSpecification: nil,
                                         imageBufferAttributes: nil,
                                         outputCallback: recordPtr,
                                         decompressionSessionOut: &newSession)
        }
        guard status == noErr, let newSession else {
            print("[decoder] oturum oluşturulamadı: \(status)")
            return
        }
        lock.lock()
        session = newSession
        lock.unlock()
    }

    /// Sıkışık örnek tamponunu çöz.
    ///
    /// DecodeFrame **kilidin altında** çağrılır. Kilidi bırakıp öyle çağırmak,
    /// `invalidate()`'ın tam o sırada aynı oturumu geçersiz kılmasına izin
    /// verirdi — bu VideoToolbox'ta bilinen crash/tanımsız davranış kalıbıdır.
    func decode(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard let session else { return }
        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        let status = VTDecompressionSessionDecodeFrame(session,
                                                       sampleBuffer: sampleBuffer,
                                                       flags: flags,
                                                       frameRefcon: nil,
                                                       infoFlagsOut: nil)
        if status != noErr && status != kVTVideoDecoderMalfunctionErr {
            return
        }
    }

    func invalidate() {
        invalidateSession()
        lock.lock()
        formatDesc = nil
        lock.unlock()
    }

    private func invalidateSession() {
        // Invalidate KİLİT ALTINDA yapılır: decode() ile eşzamanlı çalışması
        // VideoToolbox'ta bilinen crash/tanımsız davranış kalıbıdır.
        lock.lock()
        defer { lock.unlock() }

        if let current = session {
            VTDecompressionSessionInvalidate(current)
        }
        session = nil
    }

    deinit {
        invalidateSession()
    }
}
