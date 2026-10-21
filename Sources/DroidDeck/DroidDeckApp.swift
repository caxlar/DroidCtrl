import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: DeviceStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cihazda encoder/yayın bırakmamak için yayını kes.
        store?.shutdownForTermination()
    }

    func applicationDidHide(_ notification: Notification) {
        // Uygulama gizlendiğinde de yayını kes — cihaz boş yere kodlama yapmasın.
        store?.shutdownForTermination()
    }
}

@main
@MainActor
struct DroidDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DeviceStore()

    init() {
        // Tanılama modları arayüz açmadan çalışır:
        //   DroidDeck --selftest       ayrıştırıcı testleri (cihaza dokunmaz)
        //   DroidDeck --probe          gerçek cihaza karşı okuma testleri
        //   DroidDeck --probe-control  + görünmez bir tuş basımı dener
        //   DroidDeck --render <png>   arayüzü PNG olarak render eder
        if CommandLine.arguments.contains("--selftest") {
            Selftest.run()
        }
        if let renderIndex = CommandLine.arguments.firstIndex(of: "--render"),
           renderIndex + 1 < CommandLine.arguments.count {
            let mode = (renderIndex + 2 < CommandLine.arguments.count)
                ? CommandLine.arguments[renderIndex + 2] : "main"
            UIRenderer.render(to: CommandLine.arguments[renderIndex + 1], mode: mode)
        }
        if CommandLine.arguments.contains("--probe") {
            Probe.run()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--labels-file"),
           i + 2 < CommandLine.arguments.count {
            LabelCLI.fromFiles(manifestPath: CommandLine.arguments[i + 1],
                               arscPath: CommandLine.arguments[i + 2])
        }
        if let i = CommandLine.arguments.firstIndex(of: "--arsc-raw"),
           i + 3 < CommandLine.arguments.count {
            LabelCLI.arscRaw(arscPath: CommandLine.arguments[i + 1],
                             typeId: Int(CommandLine.arguments[i + 2]) ?? 0,
                             entryId: Int(CommandLine.arguments[i + 3]) ?? 0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--arsc-trace"),
           i + 2 < CommandLine.arguments.count {
            LabelCLI.arscTrace(arscPath: CommandLine.arguments[i + 1],
                               idHex: CommandLine.arguments[i + 2])
        }
        if CommandLine.arguments.contains("--telemetry") {
            LabelCLI.telemetryProbe()
        }
        if CommandLine.arguments.contains("--labels") {
            LabelCLI.fromDevice()
        }
        if CommandLine.arguments.contains("--preview-test") {
            LabelCLI.previewTest()
        }
    }

    var body: some Scene {
        WindowGroup("DroidDeck") {
            StudioShell()
                .environmentObject(store)
                .task {
                    appDelegate.store = store
                    store.refresh()
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 822)
        .commands {
            // Yeni pencere komutunu kaldırıyoruz: tek bir kumanda penceresi yeterli.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("ADB Sunucusunu Yeniden Başlat") {
                    store.restartADBServer()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Araç Yollarını Yenile") {
                    store.reloadToolPaths()
                }
            }
        }

        // Sistem tepsisi: pencere kapalıyken bile cihaz seç + temel tuşlar.
        MenuBarExtra("DroidDeck", systemImage: "tv") {
            MenuBarPanel(store: store)
        }
        .menuBarExtraStyle(.menu)
    }
}
