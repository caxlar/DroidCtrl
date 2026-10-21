import SwiftUI
import AppKit

/// `DroidDeck --render <yol.png>`: Arayüzü gerçek verilerle PNG olarak
/// render eder. Ekran kayıt izni olmadan arayüz düzenini doğrulamak için.
enum UIRenderer {

    @MainActor
    static func render(to path: String, mode: String = "main") -> Never {
        let store = DeviceStore()

        if mode == "pairing" {
            // ScrollView ImageRenderer'da çizilmediği için talimatları doğrudan çizeriz.
            let size = CGSize(width: 640, height: 1260)
            let content = PairingInstructions()
                .padding(20)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
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

        let size = CGSize(width: 1280, height: 822)
        let content = StudioShell()
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
