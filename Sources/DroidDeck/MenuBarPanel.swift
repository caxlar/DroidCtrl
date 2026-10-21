import SwiftUI
import AppKit

/// Sistem tepsisi (menu bar) modu.
///
/// Amaç: uygulama penceresi kapalıyken bile tek tıkla cihaz seçip temel
/// tuşları göndermek — TV kumandası hissi. UI bilinçli olarak sade; daha
/// sonra yeniden tasarlanacak.
struct MenuBarPanel: View {
    @ObservedObject var store: DeviceStore

    var body: some View {
        // Cihaz seçimi
        Menu {
            ForEach(store.devices) { device in
                Button {
                    store.selectedDeviceID = device.id
                } label: {
                    if device.id == store.selectedDevice?.id {
                        Label(device.displayName, systemImage: "checkmark")
                    } else {
                        Text(device.displayName)
                    }
                }
            }
            if store.devices.isEmpty {
                Text("Cihaz yok — ana pencereden tarayın")
            }
        } label: {
            Text("Cihaz: \(store.selectedDevice?.displayName ?? "seçili değil")")
        }

        Divider()

        Button("Ekranı Aç / Kilidi Aç") { store.wakeAndUnlock() }
            .keyboardShortcut("u", modifiers: [.command, .shift])

        Button("Ana Sayfa") { store.sendKey(.home) }
            .keyboardShortcut("1", modifiers: [.command])
        Button("Geri") { store.sendKey(.back) }
            .keyboardShortcut("[", modifiers: [.command])
        Button("Oynat / Duraklat") { store.sendMedia(.playPause) }
            .keyboardShortcut("p", modifiers: [.command])
        Button("Sesi Aç") { store.sendKey(.volumeUp) }
            .keyboardShortcut("+", modifiers: [.command])
        Button("Sesi Kıs") { store.sendKey(.volumeDown) }
            .keyboardShortcut("-", modifiers: [.command])

        Divider()

        if store.previewActive {
            Button("Yayını Durdur") { store.stopPreview() }
        } else {
            Button("Yayını Başlat") { store.startPreview() }
                .disabled(store.selectedDevice?.state.isControllable != true)
        }

        Divider()

        Button("Ana Pencereyi Göster") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
        }

        Button("DroidDeck'ten Çık") { NSApp.terminate(nil) }
    }
}
