//
//  DashboardHost.swift — DroidDeck
//
//  Kullanıcının yeni arayüzünü (TrebleDroidPixelDashboard) DroidDeck'in
//  gerçek durumu ve işlevleriyle birleştiren sarmalayıcı.
//

import SwiftUI

/// Yeni arayüzün giriş görünümü.
///
/// Tasarım dosyası (`TrebleDroidPixelDashboard.swift`) olduğu gibi korunur;
/// yalnızca veri ve eylem bağlaması bu sarmalayıcıdan yapılır.
struct DashboardHost: View {
    @EnvironmentObject private var store: DeviceStore
    @StateObject private var bridge: DashboardBridge

    init() {
        // `@EnvironmentObject` init sırasında erişilemez; köprü, gerçek
        // store referansını `.task` içinde bağlar.
        _bridge = StateObject(wrappedValue: DashboardBridge(store: DeviceStore()))
    }

    var body: some View {
        TrebleDroidPixelDashboard(
            devices: bridge.visualDevices,
            apps: bridge.visualApps,
            actions: bridge.makeActions(),
            screenContent: bridge.screenContent
        )
        .task {
            // Gerçek store'u köprüye bağla.
            bridge.store = store
            bridge.objectWillChange.send()
            store.refresh()
        }
        .onChange(of: store.devices.count) {
            bridge.objectWillChange.send()
        }
        .onChange(of: store.apps.count) {
            bridge.objectWillChange.send()
        }
        .onChange(of: store.previewActive) {
            bridge.objectWillChange.send()
        }
    }
}
