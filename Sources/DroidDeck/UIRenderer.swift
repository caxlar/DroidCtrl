import SwiftUI
import AppKit

// This Palette is a duplicate because TrebleDroidDashboard's Palette is private.
// Both files need Color(rgb:) support, which is now public in TrebleDroidDashboard.
enum RendererPalette {
    static let background = Color(rgb: 0x070D20)
    static let sidebar = Color(rgb: 0x0B182B)
    static let surface = Color(rgb: 0x101D33)
    static let raised = Color(rgb: 0x18263D)
    static let field = Color(rgb: 0x1B293F)
    static let textMuted = Color(rgb: 0x9BAECA)
    static let outline = Color.white.opacity(0.095)
    static let blue = Color(rgb: 0x1478FF)
    static let green = Color(rgb: 0x19DC74)
    static let orange = Color(rgb: 0xFF9500)
    static let red = Color(rgb: 0xFF3B30)
}

/// `DroidCtrl --render <yol.png>`: Arayüzü gerçek verilerle PNG olarak
/// render eder. Ekran kayıt izni olmadan arayüz düzenini doğrulamak için.
enum UIRenderer {

    // Static apps array for rendering - defined at enum level where Palette is accessible
    private static let renderApps: [TDVisualApp] = [
        .init(name: "Chrome", packageName: "com.android.chrome", symbol: "globe", color: RendererPalette.background),
        .init(name: "Play Store", packageName: "com.android.vending", symbol: "play.fill", color: RendererPalette.green),
        .init(name: "Kamera", packageName: "com.google.android.GoogleCamera", symbol: "camera.fill", color: RendererPalette.textMuted),
        .init(name: "Ayarlar", packageName: "com.android.settings", symbol: "gearshape.fill", color: RendererPalette.blue),
        .init(name: "YouTube", packageName: "com.google.android.youtube", symbol: "play.rectangle.fill", color: RendererPalette.red),
        .init(name: "Gmail", packageName: "com.google.android.gm", symbol: "envelope.fill", color: RendererPalette.red)
    ]

    // Static data for rendering - defined at enum level where Palette is accessible
    private static let renderDevices: [(id: String, address: String, connected: Bool, nativePixelSize: CGSize)] = [
        (id: "adb-R8...HeVpcV", address: "192.168.1.8:34919", connected: true,
         nativePixelSize: CGSize(width: 1280, height: 1104)),
        (id: "adb-2...0131507", address: "192.168.1.7:5555", connected: false,
         nativePixelSize: CGSize(width: 800, height: 1280))
    ]

    @MainActor
    static func render(to path: String, mode: String = "main") -> Never {
        let store = DeviceStore()

        if mode == "dashboard" {
            // Yeni arayüz tasarımının render'ı (görsel doğrulama).
            let size = CGSize(width: 1672, height: 941)
                        let content = TrebleDroidDashboard(
                devices: renderDevices.map { .init(id: $0.id, address: $0.address, connected: $0.connected,
                                                  nativePixelSize: $0.nativePixelSize) },
                apps: renderApps,
                actions: TDVisualActions(),
                previewActive: false,
                sidebarSection: .constant("devices"),
                currentQuality: "quality_balanced",
                screenContent: nil
            )
            .frame(width: size.width, height: size.height)
            writePNG(content, size: size, path: path)
        }

        if mode == "swatch" {
            // Teşhis: PNG yazıcısı renkleri doğru mu aktarıyor?
            let size = CGSize(width: 400, height: 100)
            let content = HStack(spacing: 0) {
                Color.white.frame(width: 100, height: 100)
                Color.gray.frame(width: 100, height: 100)
                Color.blue.frame(width: 100, height: 100)
                Color.red.frame(width: 100, height: 100)
            }
            .frame(width: size.width, height: size.height)
            writePNG(content, size: size, path: path)
        }

        if mode == "pairing" {
            // ScrollView ImageRenderer'da çizilmediği için talimatları doğrudan çizeriz.
            let size = CGSize(width: 640, height: 1260)
            let content = PairingInstructions()
                .padding(20)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color.white)
            writePNG(content, size: size, path: path)
        }

        // Arayüzün boş kalmaması için gerçek cihaz verisini senkron doldur.
        if let adb = store.adb {
            store.devices = adb.listDevices()
            store.mdnsServices = adb.listMDNSServices()
            store.selectedDeviceID = store.devices.first(where: { $0.state.isControllable })?.id
                ?? store.devices.first?.id

            if let serial = store.selectedDeviceID {
                let locale = LabelCLI.deviceLocale(adb: adb, serial: serial)
                let cache = LabelCache.forSerial(serial)

                var apps = adb.listLaunchableApps(serial).map { app -> AndroidApp in
                    var copy = app
                    copy.label = cache.label(for: app.packageName)
                    return copy
                }
                for index in apps.indices where apps[index].label == nil {
                    let result = LabelCLI.label(for: apps[index].packageName,
                                                adb: adb, serial: serial, locale: locale)
                    if let label = result.label {
                        apps[index].label = label
                        cache.store(label, for: apps[index].packageName)
                    }
                }
                cache.save()
                store.apps = apps
                store.labelStatus = "Gerçek ad: \(apps.filter { $0.isRealLabel }.count)/\(apps.count)"
            }
            store.statusMessage = "\(store.devices.count) cihaz · render"
        }

        let size = CGSize(width: 1180, height: 1080)
        let content = RenderHost()
            .environmentObject(store)
            .frame(width: size.width, height: size.height)
        writePNG(content, size: size, path: path)
    }

    @MainActor
    private static func writePNG<V: View>(_ content: V, size: CGSize, path: String) -> Never {
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.scale = 2

        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("Render başarısız.\n".utf8))
            exit(1)
        }

        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("Render yazıldı: \(path)  (\(Int(size.width))x\(Int(size.height)) @2x)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Yazma hatası: \(error)\n".utf8))
            exit(1)
        }
    }
}
