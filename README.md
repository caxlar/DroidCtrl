# DroidDeck

Mac'ten Android cihazlarınızı (TV, telefon, tablet) yönetmek için yerel uygulama.

Ağdaki Android cihazları listeler, seçtiğiniz cihazı uzaktan kumandayla kontrol eder:
program açma, klavye/mouse, medya tuşları ve ekran yansıtma.

## Nasıl çalışır

Her şey **ADB** (Android Debug Bridge) üzerinden yürür. Uygulama `adb` ve `scrcpy`
komutlarını saran bir SwiftUI arayüzüdür; cihazlara doğrudan konuşmaz.

```
┌─────────────────────────────┐
│  DroidDeck (SwiftUI)         │
│  cihaz listesi · kumanda     │
└──────────┬──────────────────┘
           │ Process() ile
    ┌──────┴──────┐     ┌──────────┐
    │     adb     │     │  scrcpy  │
    └──────┬──────┘     └────┬─────┘
           │  TCP / mDNS     │
        ┌──┴──────────────────┴──┐
        │   Android cihazlar      │
        └─────────────────────────┘
```

## Gereksinimler

- macOS 14+
- `adb` — `brew install --cask android-platform-tools`
- `scrcpy` (ekran yansıtma için) — `brew install scrcpy`
- Cihazlarda **Geliştirici seçenekleri → USB hata ayıklama** (veya TV'de
  **ADB hata ayıklama / Uzaktan hata ayıklama**) açık olmalı

## Derleme ve çalıştırma

```bash
cd DroidDeck
swift build
./.build/debug/DroidDeck
```

Xcode gerekmez. Günlük kullanım için derleme tipini değiştirin:
`swift build -c release` → `.build/release/DroidDeck`

## İlk bağlantı: eşleştirme

Android, bir cihazı bir bilgisayara **ilk kez** bağladığında güvenlik için eşleştirme
ister. Uygulama bunu bir sihirbaz hâline getirir — **sadece sen "Eşleştir" dediğinde açılır.**

1. Soldaki listede cihaz satırında **Eşleştir**'e bas
   (veya "Elle Bağlan" altındaki **Eşleştir**'i kullan).
2. Sihirbaz telefonda yapman gerekenleri adım adım yazar.
3. Telefonda **Ayarlar → Geliştirici seçenekleri → Kablosuz hata ayıklama** →
   **"Eşleştirme koduyla cihaz eşleştir"** penceresini aç.
4. Uygulama o pencereyi **otomatik bulur** (mDNS `_adb-tls-pairing._tcp`),
   sen yalnızca ekrandaki 6 haneli kodu yazarsın.
5. Eşleşme tamamlanır ve cihaz **otomatik bağlanır**.

Eşleştirme **bir kez** yapılır; sonraki bağlantılarda kod istenmez. Kod kaydedilmez
ve kimseyle paylaşılmaz.

> Telefon/tablet **5555 portunu kullanmaz** — "Kablosuz hata ayıklama" rastgele bir
> port atar. Bu yüzden elle `IP:5555` yazmak telefonlarda çalışmaz; mDNS keşfini
> veya eşleştirme sihirbazını kullanın. Android TV'ler genelde `IP:5555` kullanır.

## Kullanım

1. **Yenile** ile ağdaki cihazları tarayın.
   - `adb devices` kayıtları sol tarafta listelenir.
   - mDNS (`_adb._tcp`, `_adb-tls-connect._tcp`) ile yayınlanan cihazlar
     "Ağda Bulunanlar" bölümünde görünür — **Bağlan** ile ekleyin.
   - Görünmüyorsa **Elle Bağlan** ile `IP:port` girin (Android TV'lerde
     genelde `IP:5555`).
2. Cihaz satırına tıklayın.
3. Kumanda paneli açılır:
   - **Gezinme** — Geri, Ana Sayfa, Menü, dpad, Güç, Ayarlar, Bilgi, Ara,
     altta ince **ses satırı** (Ses −, Sessiz, Ses +)
   - **Ekran** — cihazın canlı görüntüsü bu küçük alanda gösterilir
   - **Klavye** — odaklı alana metin yazar
   - **Uygulamalar** — ana ekrandaki uygulamaları **gerçek adlarıyla** listeler,
     tıklayınca açar

## Ekran önizleme

"Ekran" kartındaki kutunun ortasındaki **▶** ikonuna (veya alttaki
**Ekranı Göster** butonuna) basınca cihazın canlı görüntüsü o küçük alanda
açılır ve **doğrudan kontrol edilebilir**:

- Tıkla → dokun, sürükle → kaydır/sürükle
- Kaydırma tekerleği → kaydırma
- Klavye → cihaza yazılır (oklar, Enter, Backspace, Escape de çalışır)
- Sağ tık → Geri

Sağ üst köşedeki **⛶** ikonu (veya alttaki **Büyüt** butonu) cihaz ekranını
ayrı, büyük bir pencerede açar — scrcpy'nin kendi penceresi. Küçük alanda
işinizi görmek istemiyorsanız doğrudan büyütüp oradan devam edebilirsiniz.

Bu özellik scrcpy'nin **kendi video protokolünü** kullanan yerleşik bir
istemciyle çalışır: `scrcpy-server` cihaza itilir, H.264 akışı macOS'un
donanımsal video katmanında (`AVSampleBufferDisplayLayer`) çözülür, dokunma
ve tuş olayları protokolün kontrol soketinden gönderilir. Yani ayrı bir
pencere hizalama hilesi yoktur; görüntü gerçekten uygulamanın içindedir.

## Uygulama adları nereden geliyor?

Cihaz çekmecesindeki adlar (Ayarlar, Kamera, Hesap Makinesi…) ADB'nin hazır
bir komutuyla verilmez. DroidDeck bunları APK'nın içinden okur:

1. `cmd package query-activities` ile başlatılabilir uygulamalar bulunur.
2. Her uygulamanın `AndroidManifest.xml` ve `resources.arsc` girdileri
   APK içinde `unzip -p` ile **yalnızca bu iki dosya** olarak alınır
   (APK'nın tamamı indirilmez).
3. Binary XML + ARSC ayrıştırıcıyla `android:label` çözülür; cihazın yerel
   ayarı (ör. Türkçe) varsa o dildeki karşılığı seçilir.

Sonuçlar `~/Library/Application Support/DroidDeck/` altına önbelleklenir;
ikinci açılışta adlar anında gelir.

## Tanılama modları

Arayüz açılmadan çalışır:

```bash
./.build/debug/DroidDeck --selftest          # ayrıştırıcı testleri (cihaza dokunmaz)
./.build/debug/DroidDeck --probe             # gerçek cihaza karşı okuma testleri
./.build/debug/DroidDeck --probe-control     # + görünmez bir tuş basımı dener
./.build/debug/DroidDeck --render out.png    # arayüzü PNG olarak render eder
```

`--probe-control` yalnızca `KEYCODE_UNKNOWN` (0) gönderir; cihazda görünür
bir etkisi yoktur.

## Cihaz tarafı kurulum

**Telefon / tablet (Android 11+):**
Ayarlar → Geliştirici seçenekleri → **Kablosuz hata ayıklama** → eşleştirme.
Bir kez eşleştirildikten sonra otomatik bulunur.

**Android TV:**
Ayarlar → Geliştirici seçenekleri → **ADB hata ayıklama** (bazı markalarda
"Uzaktan hata ayıklama"). Bağlantı genelde `IP:5555` üzerinden yapılır.

> Not: ADB tam yetki demektir (ekran görüntüsü, dosya, uygulama kurma).
> Uygulamayı yalnızca kendi ev ağınızda çalıştırın.

## Sınırlamalar

- İlk liste için gerçek adların çözümü cihaz başına ~30-60 saniye sürebilir
  (her uygulama için iki küçük dosya okunur). Sonrasında önbellek sayesinde
  anlıktır; **Listele** ile yeniden çekebilirsiniz.
- `resources.arsc` içinde Türkçe karşılığı olmayan adlar İngilizce görünür.
- **scrcpy kurulu değilse** "Ekranı Göster" devre dışı kalır; kumanda tuşları
  yine çalışır.
- mDNS yayını cihazdan cihaza değişir; Android TV'ler genelde mDNS kullanmaz.
  Bu durumda **Elle Bağlan** ile bağlanın.
- IP adresleri DHCP ile değişebilir. Router'dan MAC bazlı rezervasyon yapın
  ya da mDNS keşfini kullanın.

## Dosyalar

| Dosya | Görev |
|---|---|
| `Support.swift` | süreç çalıştırıcı, kaçış/yardımcılar |
| `ADB.swift` | adb/scrcpy sarmalayıcısı + saf ayrıştırıcılar |
| `Models.swift` | cihaz, uygulama, klavye kodu modelleri |
| `ApkLabel.swift` | binary XML + resources.arsc ayrıştırıcıları |
| `LabelCLI.swift` | cihazdan etiket çıkarma ve tanılama komutları |
| `LabelCache.swift` | etiket önbelleği (disk) |
| `DeviceStore.swift` | uygulama durumu ve tüm ADB işlemleri |
| `ScrcpyClient.swift` | scrcpy video/kontrol protokolü istemcisi |
| `VideoSurface.swift` | H.264 render katmanı + fare/klavye olayları |
| `LogBox.swift` | sunucu çıktısı toplayıcı |
| `ContentView.swift` | kenar çubuğu, satırlar, durum çubuğu |
| `RemotePanelView.swift` | kumanda paneli ve kartlar |
| `Probe.swift` / `Selftest.swift` / `UIRenderer.swift` | tanılama modları |
