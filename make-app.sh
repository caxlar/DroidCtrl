#!/bin/bash
# DroidDeck'i çift tıklanabilir macOS uygulaması olarak paketler.
# Kullanım:  ./make-app.sh [hedef.yol]
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DroidDeck"
DEST="${1:-/Applications/${APP_NAME}.app}"

# /Applications yazılabilir değilse kullanıcı klasörüne kur.
if ! mkdir -p "$(dirname "$DEST")" 2>/dev/null || [ ! -w "$(dirname "$DEST")" ]; then
    DEST="$HOME/Applications/${APP_NAME}.app"
    mkdir -p "$HOME/Applications"
fi

echo "Derleniyor (release)…"
swift build -c release

echo "Paketleniyor: $DEST"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp .build/release/DroidDeck "$DEST/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "$DEST/Contents/Info.plist"
cp Resources/TabletPreview.png "$DEST/Contents/Resources/TabletPreview.png"

# Localization files
for lang in en tr es zh-Hans de it; do
    mkdir -p "$DEST/Contents/Resources/${lang}.lproj"
    cp "Resources/${lang}.lproj/Localizable.strings" "$DEST/Contents/Resources/${lang}.lproj/"
done

# --- İmzalama -------------------------------------------------------------
#
# Gatekeeper: ad-hoc imzalı bir uygulama kendi makinenizde çalışır ama başka
# bir Mac'te indirildiğinde "doğrulanamamış geliştirici" der. Kalıcı çözüm
# Developer ID + notarizasyondur.
#
# Kurulum (bir kez):
#   1. Apple Developer Program'a katıl (yıllık ücret)
#   2. "Developer ID Application" sertifikası üret ve Keychain'e ekle
#   3. Notarizasyon için kimlik bilgisi kaydet:
#        xcrun notarytool store-credentials "droiddeck-notary" \
#            --apple-id "sen@ornek.com" --team-id "ABCDE12345"
#   4. Aşağıdaki NOTARY_PROFILE değişkenini "droiddeck-notary" yap
#
# Bu adımlar yapılmışsa script otomatik olarak imzalar + notarize eder +
# staple eder. Yoksa ad-hoc imza ile devam eder ve dürüstçe söyler.

NOTARY_PROFILE="${NOTARY_PROFILE:-droiddeck-notary}"

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/grep -m1 'Developer ID Application' \
    | /usr/bin/sed -E 's/.*"(.+)".*/\1/' || true)"

if [ -n "${IDENTITY:-}" ]; then
    echo "İmzalanıyor: $IDENTITY"
    codesign --force --options runtime --timestamp \
             --sign "$IDENTITY" "$DEST" >/dev/null

    echo "Notarizasyona gönderiliyor…"
    ZIP="$(mktemp -d)/${APP_NAME}.zip"
    ditto -c -k --keepParent "$DEST" "$ZIP"

    if SUBMIT="$(xcrun notarytool submit "$ZIP" \
                    --keychain-profile "$NOTARY_PROFILE" \
                    --wait 2>&1)"; then
        echo "Notarizasyon tamam — staple ediliyor."
        xcrun stapler staple "$DEST" >/dev/null
        echo "✓ İmzalı + notarize edilmiş uygulama hazır."
    else
        echo "⚠ Notarizasyon yapılamadı (kimlik eksik veya hata)."
        echo "  Uygulama yine imzalı, ama Gatekeeper başka Mac'te uyarabilir."
        echo "  Ayrıntı: $SUBMIT"
    fi
else
    # Ad-hoc imza: Gatekeeper'ın kendi makinenizde takılmasını önler.
    codesign --force --sign - "$DEST" >/dev/null
    echo "⚠ 'Developer ID Application' sertifikası bulunamadı — ad-hoc imza."
    echo "  Kendi makinenizde çalışır. Başka Mac'te Gatekeeper uyarır."
    echo "  Kalıcı çözüm için: Apple Developer Program + Developer ID sertifikası."
    echo "  Adımlar için make-app.sh içindeki açıklamalara bakın."
fi

echo ""
echo "Kuruldu: $DEST"
echo "Açmak için:  open \"$DEST\""
