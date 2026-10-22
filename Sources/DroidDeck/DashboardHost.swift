//
//  DashboardHost.swift — DroidCtrl
//
//  Kullanıcının yeni arayüzünü (TrebleDroidDashboard) DroidCtrl'in
//  gerçek durumu ve işlevleriyle birleştiren sarmalayıcı.
//

import SwiftUI

/// Yeni arayüzün giriş görünümü.
///
/// Tasarım dosyası (`TrebleDroidDashboard.swift`) olduğu gibi korunur;
/// yalnızca veri ve eylem bağlaması bu sarmalayıcıdan yapılır.
///
/// ÖNEMLİ: Burada SAHTE bir `DeviceStore` ÜRETİLMEZ. Eskiden init içinde
/// ikinci bir store açılıyordu; bu iki kez tarama/timer başlatıyor ve
/// düğme eylemleri yanlış store'a gidiyordu.
struct DashboardHost: View {
    @ObservedObject var store: DeviceStore
    @ObservedObject var bridge: DashboardBridge

    var body: some View {
        TrebleDroidDashboard(
            devices: bridge.visualDevices,
            apps: bridge.visualApps,
            actions: bridge.makeActions(),
            previewActive: store.previewActive,
            sidebarSection: $bridge.sidebarSection,
            currentQuality: store.previewQuality.rawValue,
            screenContent: bridge.screenContent
        )
        .onAppear {
            bridge.bind(to: store)
            store.refresh()
        }
        .onChange(of: store.selectedDeviceID) {
            bridge.deviceSelectionChanged()
        }
        .onChange(of: store.devices.count) {
            bridge.deviceSelectionChanged()
        }
        .onChange(of: store.apps.count) {
            bridge.objectWillChange.send()
        }
        .onChange(of: store.previewActive) {
            bridge.objectWillChange.send()
        }
    }
}
