#!/bin/bash
# Membuat dist/install-LiteScroller.command: installer satu file
# (source Swift + Info.plist ditanam di dalamnya, compile di Mac pengguna)
set -e
cd "$(dirname "$0")/.."
mkdir -p dist
OUT="dist/install-LiteScroller.command"

{
cat <<'HEAD'
#!/bin/bash
# ============================================================
#  Installer LiteScroller
#  Jalankan:  bash install-LiteScroller.command
#  (compile + pasang ke /Applications + jalankan otomatis)
# ============================================================
set -e
clear
echo "=========================================="
echo "   Installer LiteScroller"
echo "=========================================="

# 1. Cek versi macOS (butuh 13 Ventura ke atas)
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MAJOR" -lt 13 ]; then
  echo "❌ Butuh macOS 13 (Ventura) atau lebih baru. Versi Anda: $(sw_vers -productVersion)"
  read -n 1 -s -r -p "Tekan tombol apa saja untuk keluar..."; exit 1
fi

# 2. Cek compiler Swift (Xcode Command Line Tools)
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
  echo "⚠️  Xcode Command Line Tools belum terpasang."
  echo "   Jendela instalasi Apple akan muncul — klik 'Install' dan tunggu sampai selesai."
  echo "   Setelah itu, jalankan installer ini lagi."
  xcode-select --install 2>/dev/null || true
  read -n 1 -s -r -p "Tekan tombol apa saja untuk keluar..."; exit 0
fi

# 3. Siapkan folder kerja sementara
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
APP="LiteScroller.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 4. Source code aplikasi
cat > main.swift <<'SWIFT_EOF'
HEAD
cat Sources/LiteScroller/main.swift
echo "SWIFT_EOF"
echo ""
echo "cat > \"\$APP/Contents/Info.plist\" <<'PLIST'"
cat Resources/Info.plist
echo "PLIST"
cat <<'TAIL'

echo "▶ Compile (± 30 detik)..."
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/LiteScroller"

echo "▶ Codesign (ad-hoc)..."
# designated requirement cukup identifier → izin tetap berlaku setelah update / install ulang
codesign --force --sign - --identifier id.local.litescroller \
  --requirements '=designated => identifier "id.local.litescroller"' "$APP"

# 5. Tutup versi lama (kalau ada), lalu pasang
pkill -x LiteScroller 2>/dev/null || true
DEST="/Applications"
if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
rm -rf "$DEST/$APP"
cp -R "$APP" "$DEST/"
xattr -cr "$DEST/$APP" 2>/dev/null || true

echo "▶ Menjalankan LiteScroller..."
open "$DEST/$APP"

echo ""
echo "✅ Selesai! LiteScroller terpasang di: $DEST/$APP"
echo "   • Di menu bar muncul pemisah | dan tombol ‹ (kanan atas)."
echo "   • Tahan ⌘ lalu seret ikon yang ingin disembunyikan ke kiri pemisah |."
echo "   • Klik kanan ‹ untuk pilih mode (buka-tutup / scroller) dan 'Buka saat login'."
echo ""
read -n 1 -s -r -p "Tekan tombol apa saja untuk menutup jendela ini..."
TAIL
} > "$OUT"

chmod +x "$OUT"
echo "✅ $OUT"
