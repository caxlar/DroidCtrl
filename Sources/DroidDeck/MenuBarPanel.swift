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
                Text("no_devices_scan_main")
            }
        } label: {
            Text("Cihaz: \(store.selectedDevice?.displayName ?? "seçili değil")")
        }

        Divider()

        Button("wake_unlock") { store.wakeAndUnlock() }
            .keyboardShortcut("u", modifiers: [.command, .shift])

        Button("home") { store.sendKey(.home) }
            .keyboardShortcut("1", modifiers: [.command])
        Button("back") { store.sendKey(.back) }
            .keyboardShortcut("[", modifiers: [.command])
        Button("play_pause") { store.sendMedia(.playPause) }
            .keyboardShortcut("p", modifiers: [.command])
        Button("volume_up") { store.sendKey(.volumeUp) }
            .keyboardShortcut("+", modifiers: [.command])
        Button("volume_down") { store.sendKey(.volumeDown) }
            .keyboardShortcut("-", modifiers: [.command])

        Divider()

        if store.previewActive {
            Button("preview_stop") { store.stopPreview() }
        } else {
            Button("preview_play") { store.startPreview() }
                .disabled(store.selectedDevice?.state.isControllable != true)
        }

        Divider()

        Button("show_main_window") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
        }

        Button("quit_app") { NSApp.terminate(nil) }
    }
}
