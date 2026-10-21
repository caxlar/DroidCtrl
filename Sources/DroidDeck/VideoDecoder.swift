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
    /// `session` / `formatDesc` erişimini serileştirir.
    ///
    /// NEDEN KUYRUK ve NEDEN KİLİT DEĞİL: `VTDecompressionSessionDecodeFrame`
    /// bloklayıcı olabilir. Onu bir kilitin içinde çağırmak, `invalidate()`'ın
    /// aynı kilidi beklemesiyle **kilitlenmeye** yol açar (bizzat yaşandı:
    /// önizleme hiç başlamıyordu). Seri kuyruk aynı işi yapar ama kilit
    /// sırası/tutma süresi yüzünden takılmaz.
    ///
    /// GÜVENLİK KURALI: bu kuyruğun içindeyken `onFrame`'e erişilmez (callback
    /// senkron çalışırsa kendine dispatch_sync yapmak yine kilitlenme olur).
    /// Bu yüzden `onFrame` AYRI ve salt-okunur tutulur.
    private let syncQueue = DispatchQueue(label: "droiddeck.decoder.sync")

    /// Çözülmüş her kare için çağrılır (VideoToolbox iş parçacığında).
    ///
    /// YALNIZCA başlatmadan önce atanmalıdır (set-once). Kilitle korumak
    /// istenmedi: callback, `decode()`'un içindeki `DecodeFrame` çağrısıyla
    /// aynı iş parçacığında tetiklenebilir — o zaman kuyruğa tekrar girmek
    /// kilitlenme yaratırdı.
    var onFrame: ((CVImageBuffer, CMTime) -> Void)?

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
        syncQueue.sync { session = newSession }
    }

    /// Sıkışık örnek tamponunu çöz.
    ///
    /// `invalidate()` ile ÇAKIŞMAZ: her ikisi de aynı seri kuyruktan geçer.
    /// Ama kuyruğun içinde bloklayıcı çağrı yapılır ve `invalidate()` aynı
    /// kilidi beklerse KİLİTLENME olur — bu yüzden burada kilitle değil,
    /// seri kuyrukla serileştirme kullanılıyor.
    func decode(_ sampleBuffer: CMSampleBuffer) {
        syncQueue.sync {
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
    }

    func invalidate() {
        invalidateSession()
        syncQueue.sync { formatDesc = nil }
    }

    private func invalidateSession() {
        // decode() ile çakışmaması için aynı seri kuyruktan geçer.
        syncQueue.sync {
            if let current = session {
                VTDecompressionSessionInvalidate(current)
            }
            session = nil
        }
    }

    deinit {
        invalidateSession()
    }
}
