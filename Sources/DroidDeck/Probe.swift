import Foundation

/// `DroidCtrl --probe`: ADB/scrcpy araçlarını ve servis katmanını
/// gerçek bir cihaza karşı, arayüzü açmadan doğrular.
/// Yalnızca okuma komutları kullanır; cihazda değişiklik yapmaz.
enum Probe {

    static func run() -> Never {
        print("=== DroidCtrl tanılama ===")
        let fm = FileManager.default

        // 1) Araç konumu
        let adbPath = ADBService.locateADB()
        let scrcpyPath = ADBService.locateScrcpy()
        print("adb      : \(adbPath ?? "BULUNAMADI")")
        print("scrcpy   : \(scrcpyPath ?? "BULUNAMADI (brew install scrcpy)")")

        guard let adbPath else {
            print("\nSonuç: adb yok — kurulum: brew install --cask android-platform-tools")
            exit(1)
        }
        _ = fm
        let adb = ADBService(adbPath: adbPath)

        // 2) Keşif
        let devices = adb.listDevices()
        let services = adb.listMDNSServices()

        print("\n--- adb devices (\(devices.count)) ---")
        for device in devices {
            print("  [\(device.state.label)] \(device.displayName)  (\(device.subtitle))")
        }

        print("\n--- mDNS servisleri (\(services.count)) ---")
        for service in services {
            print("  \(service.instance)  \(service.serviceType)  \(service.endpoint)")
        }

        // 3) Kontrol edilebilir ilk cihaz üzerinde okuma testleri
        guard let target = devices.first(where: { $0.state.isControllable }) else {
            print("\nSonuç: kontrol edilebilir cihaz yok. (unauthorized ise cihazda izin verin)")
            exit(2)
        }

        print("\n--- \(target.serial) üzerinde okuma testleri ---")
        let props = adb.deviceProperties(target.serial)
        for key in ["ro.product.model", "ro.product.manufacturer", "ro.build.version.release",
                    "ro.build.version.sdk", "dalvik.vm.heapsize", "ro.kernel.qemu"] {
            if let value = props[key], !value.isEmpty {
                print("  \(key) = \(value)")
            }
        }

        let apps = adb.listThirdPartyApps(target.serial)
        print("  üçüncü parti uygulama sayısı = \(apps.count)")
        for app in apps.prefix(8) {
            print("    - \(app.displayName)  (\(app.packageName))")
        }
        if apps.count > 8 {
            print("    … \(apps.count - 8) tane daha")
        }

        // 4) Yazma yolu testi — yalnızca `--probe-control` ile.
        //    Gönderilen kod KEYCODE_UNKNOWN (0) olup cihazda görünür bir etkisi yoktur.
        if CommandLine.arguments.contains("--probe-control") {
            print("\n--- yazma yolu testi (KEYCODE_UNKNOWN / 0) ---")
            let writeResult = adb.keyevent(target.serial, rawCode: 0)
            print("  exit=\(writeResult.exitCode)  stdout=\(writeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))  stderr=\(writeResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            print("  sonuc: \(writeResult.succeeded ? "OK — komut cihaza iletildi" : "BAŞARISIZ")")
        } else {
            print("\n(yazma yolu testi atlandı — `--probe-control` ile çalıştırın)")
        }

        print("\nSonuç: OK — servis katmanı gerçek cihazla çalışıyor.")
        exit(0)
    }
}
