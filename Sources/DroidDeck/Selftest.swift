import Foundation

/// `DroidDeck --selftest`: Ayrıştırıcıları, gerçek cihazlardan alınmış
/// ham çıktı örnekleriyle doğrular. Ağa veya cihaza dokunmaz.
enum Selftest {

    private static var failures = 0

    static func run() -> Never {
        print("=== DroidDeck selftest ===")

        testParseDevices()
        testParseMDNSServices()
        testParseProperties()
        testParsePackages()
        testParseLaunchableApps()
        testInputTextEscaping()
        testAdbResilience()
        testFriendlyNames()

        print("")
        if failures == 0 {
            print("Sonuç: TÜM TESTLER GEÇTİ")
            exit(0)
        } else {
            print("Sonuç: \(failures) TEST BAŞARISIZ")
            exit(1)
        }
    }

    // MARK: - Testler

    private static func testParseDevices() {
        print("\n-- parseDevices --")
        // Gerçek çıktı: SM-T220 (LineageOS GSI), ağ üzerinden bağlı.
        let raw = """
        List of devices attached
        192.168.1.8:32829      device product:lineage_arm64_bgN model:TrebleDroid_with_GApps device:tdgsi_arm64_ab transport_id:55
        192.168.1.4:5555       offline
        emulator-5554          unauthorized
        """

        let devices = ADBService.parseDevices(raw)
        check(devices.count == 3, "3 cihaz ayrıştırıldı (gerçek: \(devices.count))")
        check(devices.first?.serial == "192.168.1.8:32829", "ilk seri doğru")
        check(devices.first?.state == .ready, "durum 'device' -> ready")
        check(devices.first?.model == "TrebleDroid_with_GApps", "model alan adı çözüldü (ünlüler alt çizgi)")
        check(devices.first?.product == "lineage_arm64_bgN", "product alanı çözüldü")
        check(devices.first?.connection == .wifi, "ip:port -> Wi-Fi bağlantısı")
        check(devices.first?.displayName == "TrebleDroid with GApps", "görünen ad alt çizgileri boşluğa çevirir")
        check(devices[1].state == .offline, "offline durumu tanındı")
        check(devices[2].state == .unauthorized, "unauthorized durumu tanındı")

        let empty = ADBService.parseDevices("List of devices attached\n\n")
        check(empty.isEmpty, "boş liste boş döner")
    }

    private static func testParseMDNSServices() {
        print("\n-- parseMDNSServices --")
        // Gerçek çıktı: alanlar TAB ile ayrılmış.
        let raw = "List of discovered mdns services\n"
            + "adb-R83W50F51YB-HeVpcV\t_adb-tls-connect._tcp\t192.168.1.8:32829\n"

        let services = ADBService.parseMDNSServices(raw)
        check(services.count == 1, "TAB ile ayrılmış satır ayrıştırıldı (gerçek: \(services.count))")
        check(services.first?.instance == "adb-R83W50F51YB-HeVpcV", "instance adı doğru")
        check(services.first?.serviceType == "_adb-tls-connect._tcp", "servis tipi doğru")
        check(services.first?.host == "192.168.1.8", "host çözüldü")
        check(services.first?.port == 32829, "port çözüldü")

        // Boşluk ile ayrılmış varyant da çalışmalı.
        let spaced = "List of discovered mdns services\n"
            + "adb-14141FDF600081         _adb._tcp              192.168.86.38:5555\n"
        let spacedServices = ADBService.parseMDNSServices(spaced)
        check(spacedServices.count == 1, "boşluk ile ayrılmış satır ayrıştırıldı")
        check(spacedServices.first?.port == 5555, "port 5555 çözüldü")

        let empty = ADBService.parseMDNSServices("List of discovered mdns services\n\n                    \n")
        check(empty.isEmpty, "yalnızca başlık/padding -> boş liste")
    }

    private static func testParseProperties() {
        print("\n-- parseProperties --")
        // Gerçek getprop çıktısı.
        let raw = """
        [apex.all.ready]: [true]
        [bluetooth.device.class_of_device]: [90,2,12]
        [ro.product.model]: [TrebleDroid with GApps]
        [ro.build.version.release]: [14]
        [empty.value]: []
        bozuk satir
        [eksik_deger]
        """

        let props = ADBService.parseProperties(raw)
        check(props["apex.all.ready"] == "true", "basit değer çözüldü")
        check(props["bluetooth.device.class_of_device"] == "90,2,12", "virgüllü değer çözüldü")
        check(props["ro.product.model"] == "TrebleDroid with GApps", "boşluklu değer çözüldü")
        check(props["ro.build.version.release"] == "14", "sürüm değeri çözüldü")
        check(props["empty.value"] == "", "boş değer çözüldü")
        check(props["bozuk satir"] == nil, "bozuk satır yok sayıldı")
        check(props["eksik_deger"] == nil, "değeri olmayan satır yok sayıldı")
    }

    private static func testParsePackages() {
        print("\n-- parsePackages --")
        let raw = """
        package:moe.shizuku.privileged.api
        package:com.brave.browser
        package:com.aistra.hail

        """

        let apps = ADBService.parsePackages(raw)
        check(apps.count == 3, "3 paket ayrıştırıldı (gerçek: \(apps.count))")
        check(apps.map(\.packageName).contains("com.brave.browser"), "paket adları korundu")
        check(apps.map(\.displayName) == ["Api", "Browser", "Hail"],
              "görünen ada göre alfabetik sıralama (Api < Browser < Hail)")
    }

    private static func testParseLaunchableApps() {
        print("\n-- parseLaunchableApps --")
        // Gerçek çıktı: başlık/özet satırlarında boşluk bulunur, bileşen satırlarında bulunmaz.
        let raw = """
        20 activities found:
          Activity #0:
            priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true
            com.android.contacts/.activities.PeopleActivity
          Activity #1:
            com.brave.browser/com.google.android.apps.chrome.Main
            com.aistra.hail/.ui.main.MainActivity
        """

        let apps = ADBService.parseLaunchableApps(raw)
        check(apps.count == 3, "3 başlatılabilir uygulama ayrıştırıldı (gerçek: \(apps.count))")
        check(apps.first?.packageName == "com.aistra.hail", "paket adına göre sıralama")
        check(apps.first(where: { $0.packageName == "com.brave.browser" })?.componentName
                == "com.brave.browser/com.google.android.apps.chrome.Main",
              "bileşen tam yoluyla korundu")
        check(apps.first(where: { $0.packageName == "com.aistra.hail" })?.componentName
                == "com.aistra.hail/.ui.main.MainActivity",
              "kısa bileşen yolu korundu")

        let empty = ADBService.parseLaunchableApps("0 activities found:\n")
        check(empty.isEmpty, "aktivite yoksa boş liste")
    }

    private static func testInputTextEscaping() {
        print("\n-- escapeForInputText --")
        check(Shell.escapeForInputText("merhaba dünya") == "merhaba%sdünya",
              "boşluk %s olur")
        check(Shell.escapeForInputText("a&b") == "a\\&b", "ampersand kaçırılır")
        check(Shell.escapeForInputText("it's") == "it\\'s", "tek tırnak kaçırılır")
        // Güvenlik: bunlar kaçmazsa cihaz kabuğunda komut çalıştırılabilir.
        check(Shell.escapeForInputText("`reboot`") == "\\`reboot\\`",
              "backtick kaçırılır (komut yerine koyma)")
        check(Shell.escapeForInputText("$HOME") == "\\$HOME",
              "dolar kaçırılır (değişken genişleme)")
        check(Shell.escapeForInputText("a*") == "a\\*", "yıldız kaçırılır (glob)")
        check(Shell.escapeForInputText("a;b|c") == "a\\;b\\|c", "ayraçlar kaçırılır")
        check(Shell.escapeForInputText("x\ny") == "x%sy", "satır sonu %s olur")
    }

    private static func testAdbResilience() {
        print("\n-- adb dayanıklılığı (cihazdan bağımsız) --")

        func result(_ err: String) -> CommandResult {
            CommandResult(stdout: "", stderr: err, exitCode: 1, timedOut: false)
        }

        check(isTransientADBFailure(result("error: device offline")),
              "device offline => geçici")
        check(isTransientADBFailure(result("failed to connect to '1.2.3.4:5555': No route to host")),
              "No route to host => geçici")
        check(isTransientADBFailure(result("error: closed")),
              "closed => geçici")
        check(!isTransientADBFailure(result("unknown command: foo")),
              "bilinmeyen komut => geçici DEĞİL (yeniden başlatmayı hak etmez)")
        check(!isTransientADBFailure(result("")),
              "boş sonuç => geçici değil")

        // Hız sınırı: arka arkaya restart'lar adb'yi kendisi yük yapmasın.
        // Yalnızca karar mantığı test edilir; selftest gerçekten adb'ye dokunmaz.
        AdbMaintenance.reset()
        check(AdbMaintenance.shouldRestart(), "sıfırdan sonra restart serbest")
        AdbMaintenance.markRestarted()
        check(!AdbMaintenance.shouldRestart(),
              "hız sınırı hemen ardından ikinci restart'ı engeller")
        check(AdbMaintenance.shouldRestart(at: Date().addingTimeInterval(60)),
              "sınır geçince tekrar serbest")
    }

    private static func testFriendlyNames() {
        print("\n-- friendlyName --")
        check(Shell.friendlyName(fromPackage: "com.brave.browser") == "Browser", "son segment alınır")
        check(Shell.friendlyName(fromPackage: "com.google.android.youtube") == "Youtube", "son segment alınır (2)")
    }

    // MARK: - Yardımcı

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("  ok   \(label)")
        } else {
            print("  FAIL \(label)")
            failures += 1
        }
    }
}
