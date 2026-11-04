# Video teaser

`litescroller-teaser.mp4` — teaser 28 detik, 1920×1080, 30 fps, tanpa suara.

| Detik | Adegan |
|---|---|
| 0–3,5 | Ikon + "LiteScroller — Menu bar penuh? Gulir saja." |
| 3,5–8,5 | Masalah: menu aplikasi panjang + notch menyembunyikan ikon |
| 8,5–15 | Mode scroller: klik », strip ikon tersembunyi muncul, digulir, klik DBngin |
| 15–18,5 | Empat mode (screenshot `menubar-modes.png`) |
| 18,5–22 | Menu pengaturan (screenshot `menu.png`) |
| 22–25,5 | Fitur: CPU 0% saat diam, satu file Swift, tutup otomatis, ikut tema, update dari menu, izin seperlunya |
| 25,5–28 | Penutup |

## Render ulang

Sumber animasi ada di `src/teaser.html` (memakai screenshot dari `docs/screenshots/`). Buka langsung
di browser untuk pratinjau. Untuk membuat MP4 (butuh Node + Playwright/Chromium + ffmpeg):

```bash
node video/src/render.js
```
