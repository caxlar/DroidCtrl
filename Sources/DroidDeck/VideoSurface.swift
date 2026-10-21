import SwiftUI
import AppKit
import AVFoundation
import CoreVideo
import QuartzCore

// MARK: - Video yüzeyi

/// `AVSampleBufferDisplayLayer` üzerinde çözülmüş kareleri çizer ve
/// fare/klavye olaylarını koordinata çevirir.
final class SurfaceNSView: NSView {

    /// Görünüm koordinatı + olay tipi (0=dokun-bas, 1=kaldır, 2=taşı)
    var onTouch: ((CGPoint, Int) -> Void)?
    var onScroll: ((CGPoint, CGFloat, CGFloat) -> Void)?
    var onText: ((String) -> Void)?
    var onSpecialKey: ((Int) -> Void)?    // Android keycode

    private(set) var videoSize: CGSize = .zero
    private var cachedFormatDesc: CMVideoFormatDescription?
    private let formatLock = NSLock()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) desteklenmiyor")
    }

    /// AppKit'in oluşturduğu katmanı `AVSampleBufferDisplayLayer` yapar.
    /// Doğrudan `layer = ...` atamak yerine bunu kullanmak gerekir.
    override func makeBackingLayer() -> CALayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.frame = bounds
        CATransaction.commit()
    }

    func setVideoSize(_ size: CGSize) {
        videoSize = size
    }

    /// Çözülmüş kareyi ekrana basar.
    func enqueue(imageBuffer: CVImageBuffer, pts: CMTime) {
        formatLock.lock()
        var formatDesc = cachedFormatDesc

        // Çözünürlük değiştiyse (ör. cihaz döndü) biçimi yeniden kur.
        if let existing = formatDesc {
            let dims = CMVideoFormatDescriptionGetDimensions(existing)
            if dims.width != CVPixelBufferGetWidth(imageBuffer)
                || dims.height != CVPixelBufferGetHeight(imageBuffer) {
                formatDesc = nil
                cachedFormatDesc = nil
            }
        }

        if formatDesc == nil {
            var created: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                      imageBuffer: imageBuffer,
                                                                      formatDescriptionOut: &created)
            if status == noErr {
                cachedFormatDesc = created
                formatDesc = created
            }
        }
        formatLock.unlock()
        guard let formatDesc else { return }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                              imageBuffer: imageBuffer,
                                                              formatDescription: formatDesc,
                                                              sampleTiming: &timing,
                                                              sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return }

        let targetLayer = displayLayer
        if targetLayer.status == .failed {
            targetLayer.flush()
        }
        targetLayer.enqueue(sampleBuffer)
    }

    /// Video alanının görünüm içindeki gerçek konumu (letterbox dahil).
    private func videoRect() -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let w = videoSize.width * scale
        let h = videoSize.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// Görünüm noktasını video koordinatına çevirir.
    func videoPoint(from viewPoint: CGPoint) -> CGPoint? {
        let rect = videoRect()
        guard rect.width > 0, rect.height > 0, videoSize.width > 0 else { return nil }
        let nx = (viewPoint.x - rect.minX) / rect.width
        let ny = (viewPoint.y - rect.minY) / rect.height
        guard nx >= -0.02, nx <= 1.02, ny >= -0.02, ny <= 1.02 else { return nil }
        return CGPoint(x: min(max(nx, 0), 1) * videoSize.width,
                       y: min(max(ny, 0), 1) * videoSize.height)
    }

    // MARK: - Fare

    private func handleMouse(_ event: NSEvent, action: Int) {
        let local = convert(event.locationInWindow, from: nil)
        guard let vp = videoPoint(from: local) else { return }
        onTouch?(vp, action)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleMouse(event, action: 0)
    }

    override func mouseDragged(with event: NSEvent) {
        handleMouse(event, action: 2)
    }

    override func mouseUp(with event: NSEvent) {
        handleMouse(event, action: 1)
    }

    override func rightMouseDown(with event: NSEvent) {
        // Sağ tık = Android BACK
        onSpecialKey?(4)
    }

    override func scrollWheel(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let vp = videoPoint(from: local) else { return }
        onScroll?(vp, event.scrollingDeltaX, event.scrollingDeltaY)
    }

    // MARK: - Klavye

    override func keyDown(with event: NSEvent) {
        if let code = Self.keyCodeMap[event.keyCode] {
            onSpecialKey?(code)
            return
        }
        guard let chars = event.characters, !chars.isEmpty else {
            super.keyDown(with: event)
            return
        }
        onText?(chars)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+C / Cmd+V gibi kısayolları cihaza göndermek yerine macOS'a bırak.
        return super.performKeyEquivalent(with: event)
    }

    /// macOS keyCode -> Android keycode (yalnızca özel tuşlar).
    static let keyCodeMap: [UInt16: Int] = [
        126: 19,   // Yukarı ok     -> DPAD_UP
        125: 20,   // Aşağı ok      -> DPAD_DOWN
        123: 21,   // Sol ok        -> DPAD_LEFT
        124: 22,   // Sağ ok        -> DPAD_RIGHT
        36: 66,    // Return        -> ENTER
        76: 66,    // Numpad Enter  -> ENTER
        51: 67,    // Delete        -> DEL (backspace)
        117: 112,  // Forward Delete-> FORWARD_DEL
        48: 61,    // Tab           -> TAB
        53: 111,   // Escape        -> ESCAPE
        49: 62,    // Space         -> SPACE
        115: 122,  // Home          -> MOVE_HOME
        119: 123,  // End           -> MOVE_END
        116: 92,   // Page Up       -> PAGE_UP
        121: 93,   // Page Down     -> PAGE_DOWN
    ]
}

// MARK: - SwiftUI sarmalayıcı

struct VideoSurface: NSViewRepresentable {
    @EnvironmentObject private var store: DeviceStore

    func makeNSView(context: Context) -> SurfaceNSView {
        let view = SurfaceNSView(frame: .zero)
        view.onTouch = { point, action in
            store.previewTouch(point: point, action: action)
        }
        view.onScroll = { point, dx, dy in
            store.previewScroll(point: point, dx: dx, dy: dy)
        }
        view.onText = { text in
            store.sendText(text)
        }
        view.onSpecialKey = { keycode in
            store.sendRawKey(keycode)
        }
        store.videoSink = view
        return view
    }

    func updateNSView(_ nsView: SurfaceNSView, context: Context) {
        if store.videoSize != .zero {
            nsView.setVideoSize(store.videoSize)
        }
    }

    static func dismantleNSView(_ nsView: SurfaceNSView, coordinator: ()) {
        nsView.displayLayer.flushAndRemoveImage()
    }
}
