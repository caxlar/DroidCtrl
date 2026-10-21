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

    /// Biçim açıklamasını ayarlar ve oturumu (yeniden) kurar.
    ///
    /// TAMAMI tek `syncQueue` bloğundadır: eşitlik kontrolü + oturum kurulumu
    /// atomiktir. Aksi hâlde `stop()` ile `setFormat()` çakışıp durdurulmuş
    /// oturumda canlı bir `VTDecompressionSession` kalabiliyordu (H6).
    func setFormat(_ desc: CMVideoFormatDescription) {
        syncQueue.sync {
            setFormatLocked(desc)
        }
    }

    /// `syncQueue` zaten eldeyken çağrılır. `decode()` içinden (malfunction
    /// kurtarması) çağrılmalıdır — aksi halde aynı seri kuyruğa dispatch_sync
    /// yapmak KİLİTLENME yaratırdı.
    private func setFormatLocked(_ desc: CMVideoFormatDescription) {
        // desc eşit AMA oturum kurulamamışsa YİNE DE yeniden dene.
        // Eskiden burada erken dönülüyordu ve bir kez başarısız olan oturum
        // bir daha hiç kurulmuyordu → kalıcı siyah ekran (H4).
        if let current = formatDesc,
           CMFormatDescriptionEqual(current, otherFormatDescription: desc),
           session != nil {
            return
        }

        if let current = session {
            VTDecompressionSessionInvalidate(current)
            session = nil
        }
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
            // Oturum kurulamadı: formatDesc'i GERİ AL ki sonraki config
            // paketi tekrar denesin. Bunu tutmak kalıcı siyah ekran yapar.
            print("[decoder] oturum oluşturulamadı: \(status)")
            formatDesc = nil
            return
        }
        session = newSession
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

        // `kVTVideoDecoderMalfunctionErr` oturumun ÖLÜ olduğu anlamına gelir.
        // Eskiden bu ve diğer hatalar sessizce yutuluyordu: ölü oturuma kare
        // basılmaya devam eder → kalıcı donma/siyah ekran (H5).
        if status == kVTVideoDecoderMalfunctionErr {
            print("[decoder] oturum bozuldu, yeniden kuruluyor")
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            // formatDesc duruyorsa bir sonraki config paketi yeniden kurar;
            // sık gelmediğinde burada kendimiz de deneyelim.
            // DİKKAT: bu blok syncQueue İÇİNDE — setFormat değil,
            // setFormatLocked çağrılmalı (aksi halde deadlock).
            if let desc = formatDesc {
                formatDesc = nil
                self.setFormatLocked(desc)
            }
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
