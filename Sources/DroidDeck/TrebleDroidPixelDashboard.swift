import SwiftUI
import AppKit

// TrebleDroid desktop visual layer — macOS 13+
// Reference canvas: 1672 × 941 points. UI only; no ADB / scrcpy implementation.
// Add Assets/TabletPreview.png to Xcode Assets as "TabletPreview" (optional).
// The live display passed into screenContent replaces the preview automatically.

private enum Palette {
    static let background = Color(rgb: 0x070D20)
    static let sidebar = Color(rgb: 0x0B182B)
    static let surface = Color(rgb: 0x101D33)
    static let raised = Color(rgb: 0x18263D)
    static let field = Color(rgb: 0x1B293F)
    static let textMuted = Color(rgb: 0x9BAECA)
    static let outline = Color.white.opacity(0.095)
    static let blue = Color(rgb: 0x1478FF)
    static let green = Color(rgb: 0x19DC74)
}
private extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 255)/255,
                  green: Double((rgb >> 8) & 255)/255,
                  blue: Double(rgb & 255)/255, opacity: 1)
    }
}

struct TDVisualDevice: Identifiable {
    var id: String
    var address: String
    var connected: Bool
    var nativePixelSize: CGSize
    var battery: Int = 85
    var version: String = "Android 13"
}
struct TDVisualApp: Identifiable {
    var id: String { packageName }
    var name: String
    var packageName: String
    var symbol: String
    var color: Color
}
/// Bind these closures to the existing application's commands without changing its implementation.
struct TDVisualActions {
    var scan: () -> Void = {}
    var connect: (TDVisualDevice) -> Void = { _ in }
    var connectAddress: (String) -> Void = { _ in }
    var selectDevice: (TDVisualDevice) -> Void = { _ in }
    var navigation: (String) -> Void = { _ in }
    var openApp: (TDVisualApp) -> Void = { _ in }
    var command: (String) -> Void = { _ in }
}

struct TrebleDroidPixelDashboard: View {
    /// Önizleme görseli. SwiftPM ile derlendiğimiz için asset kataloğu yok;
    /// paket kaynaklarından (veya geliştirme sırasında proje kökünden) okunur.
    static let tabletPreview: NSImage? = {
        let candidates = [
            Bundle.main.path(forResource: "TabletPreview", ofType: "png"),
            "Resources/TabletPreview.png",
            "../Resources/TabletPreview.png"
        ].compactMap { $0 }
        for path in candidates {
            if let img = NSImage(contentsOfFile: path) { return img }
        }
        return nil
    }()

    var devices: [TDVisualDevice] = [
        .init(id: "adb-R8...HeVpcV", address: "192.168.1.8:34919", connected: true,
              nativePixelSize: CGSize(width: 1280, height: 1104)),
        .init(id: "adb-2...0131507", address: "192.168.1.7:5555", connected: false,
              nativePixelSize: CGSize(width: 800, height: 1280))
    ]
    var apps: [TDVisualApp] = [
        .init(name: "Chrome", packageName: "com.android.chrome", symbol: "globe", color: .blue),
        .init(name: "Play Store", packageName: "com.android.vending", symbol: "play.fill", color: .green),
        .init(name: "Kamera", packageName: "com.google.android.GoogleCamera", symbol: "camera.fill", color: .gray),
        .init(name: "Ayarlar", packageName: "com.android.settings", symbol: "gearshape.fill", color: .blue),
        .init(name: "YouTube", packageName: "com.google.android.youtube", symbol: "play.rectangle.fill", color: .red),
        .init(name: "Gmail", packageName: "com.google.android.gm", symbol: "envelope.fill", color: .red)
    ]
    var actions = TDVisualActions()
    /// Önizlemenin açık olup olmadığı — düğmenin ▶/■ simgesini belirler.
    /// Kullanıcının istediği gibi: sürekli açık kalmaz, kullanıcı açar/kapatır.
    var previewActive: Bool = false
    /// Provide the existing stream view here. It is fitted to the selected native resolution.
    var screenContent: AnyView? = nil

    @State private var selectedDeviceID = ""
    @State private var address = ""
    @State private var search = ""
    @State private var keyboardText = ""
    @State private var tab: ToolsTab = .navigation
    @State private var zoom: CGFloat = 1

    private var selectedDevice: TDVisualDevice? {
        devices.first(where: { $0.id == selectedDeviceID }) ?? devices.first(where: { $0.connected })
    }
    private var filteredApps: [TDVisualApp] {
        search.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.packageName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let scale = min(max(geo.size.width / 1672, 0.80), 1.30)
            VStack(spacing: 0) {
                header
                    .frame(height: 102 * scale)
                HStack(spacing: 0) {
                    globalSidebar
                        .frame(width: 190 * scale)
                    devicePanel
                        .frame(width: 252 * scale)
                    HStack(spacing: 12 * scale) {
                        screenPanel
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        rightPanel
                            .frame(width: 398 * scale)
                    }
                    .padding(.leading, 14 * scale)
                    .padding(.trailing, 14 * scale)
                    .padding(.bottom, 12 * scale)
                }
            }
            .environment(\.layoutScale, scale)
        }
        .background {
            ZStack {
                Palette.background
                RadialGradient(colors: [Color(rgb: 0x132B68).opacity(0.5), .clear], center: .topLeading, startRadius: 30, endRadius: 950)
            }
        }
        .foregroundStyle(.white)
        .font(.system(size: 13))
        .preferredColorScheme(.dark)
        .frame(minWidth: 1240, minHeight: 720)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 23, weight: .bold))
                        .frame(width: 48, height: 48)
                        .background(Palette.blue.gradient, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TrebleDroid").font(.system(size: 21, weight: .bold))
                        Text("Android Cihaz Kontrol Merkezi").foregroundStyle(Palette.textMuted)
                    }
                }
            }
            .frame(width: 435, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                Image(systemName: "iphone").font(.system(size: 24)).foregroundStyle(Palette.blue)
                    .frame(width: 44, height: 48)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedDevice?.id ?? "Cihaz seçilmedi").font(.system(size: 17, weight: .semibold))
                    Text(selectedDevice?.address ?? "Bağlantı yok").foregroundStyle(Palette.textMuted)
                }
                statusChip
                separator
                Image(systemName: "wifi").foregroundStyle(Palette.green).font(.system(size: 20))
                Text("192.168.1.8").foregroundStyle(Palette.textMuted)
                separator
                Image(systemName: "battery.75percent").foregroundStyle(Palette.green)
                Text("%\(selectedDevice?.battery ?? 0)").foregroundStyle(Palette.textMuted)
                separator
                Image(systemName: "app.fill").foregroundStyle(Palette.green)
                Text(selectedDevice?.version ?? "Android").foregroundStyle(Palette.textMuted)
            }
            Spacer(minLength: 4)
            squareButton("display", size: 46) { actions.command("display") }
            squareButton("camera", size: 46) { actions.command("screenshot") }
            squareButton("gearshape.fill", size: 46) { actions.command("settings") }
            squareButton("ellipsis", size: 46) { actions.command("more") }
        }
        .padding(.horizontal, 32)
        .background(Palette.sidebar.opacity(0.68))
        .overlay(alignment: .bottom) { Palette.outline.frame(height: 1) }
    }

    private var separator: some View {
        Rectangle().fill(Palette.outline).frame(width: 1, height: 26)
    }
    private var statusChip: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.green).frame(width: 10, height: 10)
            Text(selectedDevice?.connected == true ? "Bağlı" : "Hazır")
                .fontWeight(.semibold).foregroundStyle(Palette.green)
        }
        .padding(.horizontal, 16).frame(height: 35)
        .background(Palette.green.opacity(0.13), in: Capsule())
    }

    private var globalSidebar: some View {
        VStack(alignment: .leading, spacing: 9) {
            sidebarLink("Cihazlar", icon: "iphone", selected: true, count: devices.count)
            sidebarLink("Ayarlar", icon: "gearshape")
            sidebarLink("Hakkında", icon: "info.circle")
            Spacer()
            HStack(spacing: 9) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Palette.green).font(.system(size: 25))
                VStack(alignment: .leading, spacing: 2) {
                    Text("ADB Servisi").fontWeight(.semibold)
                    Text("adb ve scrcpy hazır").font(.system(size: 11)).foregroundStyle(Palette.textMuted)
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .strokePanel()
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 23)
        .padding(.top, 38)
        .background(Palette.sidebar.opacity(0.65))
    }
    private func sidebarLink(_ title: String, icon: String, selected: Bool = false, count: Int? = nil) -> some View {
        Button { actions.command("sidebar:\(title)") } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 20)).frame(width: 22)
                Text(title).fontWeight(selected ? .semibold : .medium)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)").font(.system(size: 11, weight: .bold))
                        .frame(width: 23, height: 23)
                        .background(Palette.blue.opacity(0.27), in: Circle())
                }
            }
            .padding(.horizontal, 11).frame(height: 51)
            .background(selected ? Palette.blue.opacity(0.26) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    private var devicePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Cihazlar").font(.system(size: 19, weight: .bold))
                Spacer()
                squareButton("arrow.clockwise", size: 37) { actions.scan() }
            }
            Text("Ağınızdaki Android cihazlarını keşfedin ve bağlanın.")
                .font(.system(size: 11)).foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 11) {
                    Image(systemName: "wifi").font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(Palette.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Yeni Cihaz Ara").fontWeight(.bold)
                        Text("Ağınızdaki cihazları tarayın (mDNS)")
                            .font(.system(size: 10)).foregroundStyle(Palette.textMuted)
                    }
                }
                primaryButton("Cihazları Tara", icon: "arrow.clockwise") { actions.scan() }
            }
            .padding(13).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .strokePanel()
            .padding(.top, 7)
            HStack(spacing: 7) {
                Image(systemName: "desktopcomputer")
                Text("Bulunan Cihazlar (\(devices.count))").fontWeight(.semibold)
            }.padding(.top, 7)
            ForEach(devices) { device in
                deviceRow(device)
            }
            Rectangle().fill(Palette.outline).frame(height: 1).padding(.vertical, 6)
            Label("Elle Bağlan", systemImage: "link").font(.system(size: 16, weight: .bold))
            TextField("IP adresi (örn. 192.168.1.4:5555)", text: $address)
                .textFieldStyle(.plain).font(.system(size: 11))
                .padding(11).frame(height: 43)
                .background(Palette.field, in: RoundedRectangle(cornerRadius: 8))
                .strokePanel(8)
            primaryButton("Bağlan") { actions.connectAddress(address) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 25)
        .background(Palette.surface.opacity(0.42), in: RoundedRectangle(cornerRadius: 14))
        .strokePanel(14)
    }

    private func deviceRow(_ device: TDVisualDevice) -> some View {
        Button {
            selectedDeviceID = device.id
            actions.selectDevice(device)
            if !device.connected { actions.connect(device) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device.connected ? "iphone" : "wifi")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(device.connected ? Palette.blue : .white)
                    .frame(width: 48, height: 57)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.id).fontWeight(.semibold).lineLimit(1)
                    Text(device.address).font(.system(size: 11)).foregroundStyle(Palette.textMuted)
                    HStack(spacing: 6) {
                        Circle().fill(device.connected ? Palette.green : Palette.textMuted).frame(width: 9, height: 9)
                        Text(device.connected ? "Bağlı" : "Hazır")
                            .foregroundStyle(device.connected ? Palette.green : Palette.textMuted)
                    }.font(.system(size: 11))
                }
                Spacer(minLength: 0)
                Image(systemName: "gearshape").font(.system(size: 14))
                    .frame(width: 32, height: 32)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(10)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selectedDeviceID == device.id ? Palette.blue : Palette.outline,
                        lineWidth: selectedDeviceID == device.id ? 1.5 : 1))
        }.buttonStyle(.plain)
    }

    private var screenPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "ipad.landscape").foregroundStyle(Palette.textMuted)
                Text("Cihaz Ekranı").font(.system(size: 18, weight: .bold))
                Spacer()
                // Önizleme açma/kapama — sürekli açık kalmaz, cihazı yormaz.
                squareButton(previewActive ? "stop.fill" : "play.fill") {
                    actions.command("togglePreview")
                }
                squareButton("minus") { zoom = max(0.5, zoom - 0.1) }
                Text("\(Int(zoom * 100))%")
                    .fontWeight(.semibold).monospacedDigit().frame(width: 47)
                squareButton("plus") { zoom = min(2, zoom + 0.1) }
                squareButton("arrow.clockwise") { actions.command("refresh") }
                squareButton("arrow.up.left.and.arrow.down.right") { actions.command("fullscreen") }
            }
            .frame(height: 37)
            GeometryReader { geometry in
                let pixels = selectedDevice?.nativePixelSize ?? CGSize(width: 1280, height: 1104)
                let aspect = max(pixels.width, 1) / max(pixels.height, 1)
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(.black)
                    Group {
                        if let screenContent {
                            screenContent
                        } else {
                            // SwiftPM ile derlendiğimiz için asset kataloğu yok;
                            // PNG'yi paket kaynaklarından okuyoruz.
                            if let preview = Self.tabletPreview {
                                Image(nsImage: preview)
                                    .resizable()
                            } else {
                                // Kaynak yoksa arka plan siyah kalır.
                                EmptyView()
                            }
                        }
                    }
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.outline, lineWidth: 2))
            }
            HStack(spacing: 11) {
                quickAction("Ekranı Aç / Kapat", "display", "toggleScreen")
                quickAction("Ekran Görüntüsü", "camera", "screenshot")
                quickAction("APK Yükle", "square.and.arrow.up", "installApk")
                quickAction("Dosya Aktar", "folder", "fileTransfer")
            }.frame(height: 52)
        }
        .padding(13)
        .background(Palette.surface.opacity(0.90), in: RoundedRectangle(cornerRadius: 14))
        .strokePanel(14)
    }

    private enum ToolsTab: String, CaseIterable {
        case navigation = "Gezinme", keyboard = "Klavye", tools = "Araçlar"
        var icon: String {
            switch self {
            case .navigation: return "circle.grid.cross"
            case .keyboard: return "keyboard"
            case .tools: return "wrench.and.screwdriver"
            }
        }
    }
    private var rightPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(ToolsTab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        VStack(spacing: 5) {
                            Image(systemName: item.icon).font(.system(size: 18))
                            Text(item.rawValue).font(.system(size: 12))
                        }
                        .frame(maxWidth: .infinity).frame(height: 61)
                        .background(tab == item ? Palette.blue : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 13))
            .strokePanel(13)
            Group {
                switch tab {
                case .navigation: navigationGrid
                case .keyboard: keyboardView
                case .tools: toolsView
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 13))
            .strokePanel(13)
            appList
                .frame(maxHeight: .infinity)
        }
    }
    private let navigationCommands: [(String, String, String)] = [
        ("Geri", "arrow.uturn.backward", "back"), ("Ana Sayfa", "house.fill", "home"), ("Menü", "ellipsis", "menu"),
        ("Yukarı", "chevron.up", "up"), ("Tamam", "circle.fill", "ok"), ("Aşağı", "chevron.down", "down"),
        ("Sol", "chevron.left", "left"), ("Ayarlar", "gearshape.fill", "settings"), ("Sağ", "chevron.right", "right"),
        ("Güç", "power", "power"), ("Bilgi", "info.circle.fill", "info"), ("Ara", "magnifyingglass", "search")
    ]
    private var navigationGrid: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                Image(systemName: "circle.grid.cross").font(.system(size: 21))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Gezinme Kontrolleri").font(.system(size: 15, weight: .bold))
                    Text("Cihazınızı uzaktan kontrol edin.").font(.system(size: 11)).foregroundStyle(Palette.textMuted)
                }
            }.padding(.bottom, 5)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 9) {
                ForEach(navigationCommands.indices, id: \.self) { index in
                    let item = navigationCommands[index]
                    Button { actions.navigation(item.2) } label: {
                        VStack(spacing: 7) {
                            Image(systemName: item.1).font(.system(size: 21, weight: .medium))
                            Text(item.0).font(.system(size: 12))
                        }
                        .frame(maxWidth: .infinity).frame(height: 60)
                        .background(item.2 == "ok" ? Palette.blue.opacity(0.62) : Palette.raised,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(item.2 == "ok" ? Palette.blue : Palette.outline))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private var keyboardView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Klavye").font(.system(size: 16, weight: .bold))
            TextField("Metin yazın...", text: $keyboardText)
                .textFieldStyle(.plain).padding(12)
                .background(Palette.field, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                primaryButton("Gönder") { actions.command("type:\(keyboardText)") }
                primaryButton("Temizle") { keyboardText = "" }
            }
            quickAction("Enter", "return", "enter")
            quickAction("Sil", "delete.left", "delete")
        }.frame(height: 305, alignment: .top)
    }
    private var toolsView: some View {
        VStack(spacing: 12) {
            Text("Araçlar").font(.system(size: 16, weight: .bold))
            quickAction("Cihaz Bilgileri", "info.circle", "deviceInfo")
            quickAction("Ekranı Uyandır", "sun.max", "wake")
            quickAction("Uygulamaları Yenile", "arrow.triangle.2.circlepath", "loadApps")
            quickAction("Bağlantıyı Kes", "wifi.slash", "disconnect")
            quickAction("Cihazı Yeniden Başlat", "arrow.clockwise", "reboot")
        }.frame(height: 340, alignment: .top)
    }
    private var appList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Uygulamalar", systemImage: "square.grid.2x2.fill")
                    .font(.system(size: 15, weight: .bold))
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.textMuted)
                    TextField("Uygulama ara...", text: $search)
                        .textFieldStyle(.plain).font(.system(size: 11))
                }
                .padding(.horizontal, 10).frame(width: 175, height: 37)
                .background(Palette.field, in: RoundedRectangle(cornerRadius: 8))
                .strokePanel(8)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredApps) { app in
                        HStack(spacing: 11) {
                            Image(systemName: app.symbol)
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 39, height: 39)
                                .foregroundStyle(.white)
                                .background(app.color.gradient, in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.name).font(.system(size: 12, weight: .medium))
                                Text(app.packageName).font(.system(size: 10))
                                    .foregroundStyle(Palette.textMuted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Button("Aç") { actions.openApp(app) }
                                .font(.system(size: 12))
                                .buttonStyle(.plain)
                                .frame(width: 68, height: 35)
                                .background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
                                .strokePanel(8)
                        }
                        .frame(height: 49)
                        if app.id != filteredApps.last?.id {
                            Rectangle().fill(Palette.outline).frame(height: 1)
                        }
                    }
                }
            }
        }
        .padding(13)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 13))
        .strokePanel(13)
    }

    private func primaryButton(_ title: String, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity).frame(height: 43)
            .background(Palette.blue.gradient, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private func squareButton(_ icon: String, size: CGFloat = 37, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                .frame(width: size, height: size)
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.outline))
        }.buttonStyle(.plain)
    }
    private func quickAction(_ title: String, _ symbol: String, _ command: String) -> some View {
        Button { actions.command(command) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18))
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: 51)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.outline))
        }.buttonStyle(.plain)
    }
}

private struct LayoutScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
private extension EnvironmentValues {
    var layoutScale: CGFloat {
        get { self[LayoutScaleKey.self] }
        set { self[LayoutScaleKey.self] = newValue }
    }
}
private extension View {
    func strokePanel(_ radius: CGFloat = 12) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius).stroke(Palette.outline, lineWidth: 1))
    }
}
