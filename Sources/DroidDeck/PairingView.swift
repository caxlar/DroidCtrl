import SwiftUI

/// Eşleştirme talimatları — sihirbazın okunması gereken tüm metni.
/// `ScrollView` içinde kullanılır; `--render` ile tek başına da çizilebilir.
struct PairingInstructions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            intro
            steps
            troubleshooting
        }
    }

    // MARK: - Giriş

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bu işlem neden gerekiyor?")
                .font(.headline)
            Text("""
            Android, bir cihazı bir bilgisayara ilk kez bağladığında güvenlik için **eşleştirme** ister. \
            Bu, cihazın bu bilgisayara güvenmesini sağlayan tek seferlik bir işlemdir. Bir kez yapıldığında \
            bir daha kod istenmez.

            Aşağıdaki adımlar telefonda veya tablette yapılır. Teknik bilgi gerekmez — sırayla dokunmanız yeterli.
            """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Adımlar

    private var steps: some View {
        VStack(alignment: .leading, spacing: 16) {
            step(number: 1,
                 title: "Geliştirici seçeneklerini açın",
                 lines: [
                    "• Ayarlar → **Hakkında** bölümüne girin (bazı cihazlarda **Telefon hakkında** / **Tablet hakkında**).",
                    "• **Yapı numarası** yazan satırı bulun.",
                    "• O satıra **art arda 7 kez** dokunun.",
                    "• \"Artık geliştiricisiniz\" gibi bir mesaj görene kadar dokunun.",
                    "• Ayarlar'a geri dönün; artık **Geliştirici seçenekleri** menüsü görünür.",
                 ],
                 note: "Bu menü zaten açıksa bu adımı atlayın, 2. adıma geçin.")

            step(number: 2,
                 title: "Kablosuz hata ayıklamayı açın",
                 lines: [
                    "• Ayarlar → **Sistem** → **Geliştirici seçenekleri** (bazı cihazlarda doğrudan Ayarlar içinde).",
                    "• Listede **Kablosuz hata ayıklama** (Wireless debugging) seçeneğini bulun.",
                    "• Yanındaki düğmeyi **AÇIK** yapın.",
                    "• Onay sorarsa **İzin ver** deyin.",
                 ],
                 note: "Bu seçenek yalnızca cihaz aynı Wi-Fi ağındayken çalışır.")

            step(number: 3,
                 title: "Eşleştirme penceresini açın",
                 lines: [
                    "• **Yine aynı ekranda** \"**Eşleştirme koduyla cihaz eşleştir**\" (Pair device with pairing code) yazan satıra dokunun.",
                    "• Küçük bir pencere açılır. Üstünde `192.168.x.x:XXXXX` gibi bir adres yazıyor olacak — pencereyi kapatmayın.",
                    "• Pencerenin altında **6 haneli bir KOD** görünür. Aradığımız şey bu kod.",
                 ],
                 note: "Pencere açıkken bu uygulama onu otomatik fark eder; aşağıdaki durum göstergesi yeşile döner.")

            step(number: 4,
                 title: "Kodu uygulamaya yazın",
                 lines: [
                    "• Telefondaki 6 rakamı aşağıdaki alana girin.",
                    "• **Eşleştir** düğmesine basın; işlem birkaç saniye sürer.",
                    "• Bitince cihaz otomatik bağlanır ve listede **Hazır** görünür.",
                 ],
                 note: "Kod yalnızca bu işlem içindir; kaydedilmez, kimseyle paylaşılmaz.")
        }
    }

    private func step(number: Int, title: String, lines: [String], note: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(title))
                    .font(.headline)

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(lines, id: \.self) { line in
                        Text(LocalizedStringKey(line))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Sorun giderme

    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sorun yaşıyorsanız", systemImage: "lifepreserver")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                bullet("Telefon ve bu bilgisayar **aynı Wi-Fi ağında** olmalı. Farklı ağdaysa birbirlerini göremezler.")
                bullet("Eşleştirme penceresini **kapatmayın** — ekrandaki adres ve kod kısa süre için geçerlidir.")
                bullet("Kod kabul edilmezse telefonda pencereyi kapatıp **yeniden açın**; yeni kod üretir.")
                bullet("\"Kablosuz hata ayıklama\"yı bulamıyorsanız 1. adımı tamamlamış olmanız gerekir.")
                bullet("Eşleştirme **bir kez** yapılır; sonraki bağlantılarda kod istenmez.")
                bullet("Bir sorun olursa telefonu yeniden başlatmak çoğu zaman düzeltir.")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(LocalizedStringKey(text))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

/// Android cihazı bu bilgisayara eşleştirme sihirbazı.
///
/// Yalnızca kullanıcı "Eşleştir" dediğinde açılır. Telefondaki eşleştirme
/// penceresini (mDNS `_adb-tls-pairing._tcp`) otomatik bekler; kullanıcı yalnızca
/// ekranda gördüğü 6 haneli kodu yazar.
struct PairingView: View {
    @EnvironmentObject private var store: DeviceStore
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                PairingInstructions()
                    .padding(20)
            }

            Divider()

            codeArea
        }
        .frame(minWidth: 560, minHeight: 620)
        .onAppear { codeFocused = true }
        .onDisappear { store.pairingSheetDidClose() }
    }

    // MARK: - Başlık

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "link.badge.plus")
                .font(.title2)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Cihaz Eşleştirme")
                    .font(.title3.weight(.semibold))
                if !store.pairingTargetIP.isEmpty {
                    Text("Hedef: \(store.pairingTargetIP)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Kapat") {
                store.cancelPairing()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .background(.bar)
    }

    // MARK: - Kod alanı

    private var codeArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Group {
                    if store.pairingFinished {
                        Circle().fill(Color.green)
                    } else if store.pairingService != nil {
                        Circle().fill(Color.green.opacity(0.6))
                    } else {
                        Circle().fill(Color.orange)
                    }
                }
                .frame(width: 10, height: 10)

                Text(store.pairingStatus.isEmpty ? "Hazır" : store.pairingStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                if store.pairingService != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("Telefondaki eşleştirme penceresi bulundu")
                }
            }

            HStack(spacing: 10) {
                TextField("Telefondaki 6 haneli kod", text: $store.pairingCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.monospacedDigit())
                    .frame(width: 220)
                    .focused($codeFocused)
                    .disabled(store.isPairingBusy)
                    .onSubmit { store.submitPairingCode() }

                Button {
                    store.submitPairingCode()
                } label: {
                    Label("Eşleştir", systemImage: "link.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.isPairingBusy
                          || store.pairingCode.trimmingCharacters(in: .whitespaces).count < 4)

                if store.isPairingBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button("İptal") {
                    store.cancelPairing()
                }
                .controlSize(.large)
            }

            if store.pairingService == nil && !store.pairingFinished {
                Label("Eşleştirme penceresi henüz bulunamadı. Telefonda 3. adımı uygulayın — bulununca üstteki nokta yeşile döner.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Kod yalnızca bu eşleşme için geçerlidir; kaydedilmez ve kimseyle paylaşılmaz.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.bar)
    }
}
