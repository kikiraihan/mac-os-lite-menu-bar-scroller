// LiteScroller — pemisah (separator) menu bar macOS dengan empat mode:
//   • Buka-tutup : ikon di kiri pemisah disembunyikan / ditampilkan (seperti Hidden Bar)
//   • Buka-tutup timpa : sama, tapi saat terbuka menu teks aplikasi aktif (File, Edit, ...)
//                  disembunyikan sementara supaya ikon yang dibuka punya ruang
//   • Scroller   : ikon tersembunyi ditampilkan di strip yang bisa digulir, jadi tetap
//                  terjangkau walau menu aplikasi (teks di kiri) terlalu panjang / ada notch
//   • Dropdown   : ikon tersembunyi ditampilkan sebagai daftar menu di bawah tombol
// Build: ./scripts/build.sh  (butuh Xcode Command Line Tools)

import Cocoa
import ApplicationServices
import ServiceManagement

// MARK: - Accessibility (membaca & menekan ikon menu bar aplikasi lain)

func axAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func axString(_ el: AXUIElement, _ name: String) -> String? {
    guard let s = axAttr(el, name) as? String else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let pv = axAttr(el, "AXPosition"), CFGetTypeID(pv) == AXValueGetTypeID(),
          let sv = axAttr(el, "AXSize"), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(pv as! AXValue, .cgPoint, &p),
          AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}

func axTrusted(prompt: Bool) -> Bool {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(opts)
}

/// Satu ikon menu bar milik aplikasi lain
struct BarItem {
    let el: AXUIElement; let frame: CGRect; let label: String; let icon: NSImage?
    let key: String // pengenal untuk cache gambar (pid + nama item)
    var shot: NSImage? = nil // gambar asli ikon (kalau izin Rekam Layar ada)
    var appName: String? = nil // nama aplikasi biasa (bukan proses sistem), untuk judul di dropdown
}

/// PID aplikasi yang punya jendela di level status bar (= punya ikon menu bar).
/// Info ini tidak butuh izin Screen Recording (hanya PID & layer, bukan isi jendela).
func statusItemPIDs() -> Set<pid_t> {
    let layer = Int(CGWindowLevelForKey(.statusWindow))
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
    var s = Set<pid_t>()
    for w in list where (w[kCGWindowLayer as String] as? Int) == layer {
        if let pid = w[kCGWindowOwnerPID as String] as? Int { s.insert(pid_t(pid)) }
    }
    return s
}

/// Semua ikon menu bar (kecuali milik LiteScroller), urut dari kiri ke kanan
func barItems() -> [BarItem] {
    // di macOS baru jendela ikon menu bar bisa dimiliki proses sistem (bukan aplikasinya),
    // jadi daftar PID dari jendela saja tidak cukup → gabungkan dengan semua aplikasi yang berjalan
    var pids = statusItemPIDs()
    pids.formUnion(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
    pids.remove(getpid())
    let list = Array(pids)
    let lock = NSLock()
    var out: [BarItem] = []
    // dicek paralel supaya aplikasi yang lambat menjawab tidak membuat strip lama muncul
    DispatchQueue.concurrentPerform(iterations: list.count) { i in
        let found = extrasItems(pid: list[i])
        lock.lock(); out += found; lock.unlock()
    }
    return out.sorted { $0.frame.minX < $1.frame.minX }
}

/// Ikon menu bar milik satu proses (lewat AXExtrasMenuBar)
func extrasItems(pid: pid_t) -> [BarItem] {
    var out: [BarItem] = []
    let appEl = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(appEl, 0.3) // aplikasi yang macet tidak ikut membuat kita macet
    guard let bar = axAttr(appEl, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID(),
          let kids = axAttr(bar as! AXUIElement, "AXChildren") as? [AXUIElement] else { return [] }
    let app = NSRunningApplication(processIdentifier: pid)
    // ikon aplikasi hanya untuk app biasa; proses sistem (Control Center, dsb.) ikonnya generik
    var icon: NSImage?
    if let a = app, let url = a.bundleURL, !url.path.hasPrefix("/System"), let ic = a.icon?.copy() as? NSImage {
        ic.size = NSSize(width: 16, height: 16)
        icon = ic
    }
    for k in kids {
        guard let f = axFrame(k), f.width > 0, f.width < 1000 else { continue } // lewati separator panjang app lain
        let label = axString(k, "AXTitle") ?? axString(k, "AXDescription")
            ?? axString(k, "AXHelp") ?? app?.localizedName ?? "?"
        out.append(BarItem(el: k, frame: f, label: label, icon: icon, key: "\(pid):\(label)",
                           appName: icon != nil ? app?.localizedName : nil))
    }
    return out
}

// MARK: - Gambar asli ikon (opsional, butuh izin Rekam Layar)

/// CGWindowListCreateImage diambil lewat dlsym: di SDK macOS 15+ fungsi ini ditandai tidak tersedia
/// saat compile, padahal masih berjalan di sistem
typealias WindowImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
let windowImageFn: WindowImageFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil } // RTLD_DEFAULT
    return unsafeBitCast(sym, to: WindowImageFn.self)
}()

/// CGSHWCaptureWindowList (API privat SkyLight, dipakai juga oleh Ice / AltTab): bisa memotret jendela
/// ikon yang sedang di LUAR layar (saat pemisah tertutup), jadi strip / dropdown tetap memakai gambar asli ikon
typealias CGSConnectionFn = @convention(c) () -> Int32
typealias CGSCaptureFn = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, UInt32, UInt32) -> Unmanaged<CFArray>?
let cgsMainConnection: CGSConnectionFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID") else { return nil }
    return unsafeBitCast(sym, to: CGSConnectionFn.self)
}()
let cgsCaptureFn: CGSCaptureFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSHWCaptureWindowList") else { return nil }
    return unsafeBitCast(sym, to: CGSCaptureFn.self)
}()

/// Foto satu jendela walau di luar layar (ignoreGlobalClipShape = 1<<11, bestResolution = 1<<8)
func captureWindow(_ id: CGWindowID) -> CGImage? {
    guard let conn = cgsMainConnection, let cap = cgsCaptureFn else { return nil }
    var wid = id
    guard let arr = cap(conn(), &wid, 1, (1 << 11) | (1 << 8))?.takeRetainedValue(),
          CFArrayGetCount(arr) > 0, let p = CFArrayGetValueAtIndex(arr, 0) else { return nil }
    return Unmanaged<CGImage>.fromOpaque(p).takeUnretainedValue()
}

/// true kalau titik (koordinat layar) ada di area menu bar salah satu layar
func isInMenuBar(_ p: NSPoint) -> Bool {
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return false }
    let h = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
    return p.y >= screen.frame.maxY - h
}

/// Jendela terlihat di layar (bounds dalam koordinat CG: kiri-atas layar utama), urut dari yang paling depan
func onScreenWindows() -> [(pid: pid_t, layer: Int, frame: CGRect)] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
    return list.compactMap { w in
        guard let pid = w[kCGWindowOwnerPID as String] as? Int,
              let layer = w[kCGWindowLayer as String] as? Int,
              (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let f = CGRect(dictionaryRepresentation: b as CFDictionary), f.width > 1, f.height > 1 else { return nil }
        return (pid_t(pid), layer, f)
    }
}

/// Jendela paling depan di titik p (koordinat layar Cocoa), mis. ikon menu bar, menu atau popover-nya
func windowAt(_ p: NSPoint) -> (pid: pid_t, layer: Int, frame: CGRect)? {
    guard let top = NSScreen.screens.first?.frame.maxY else { return nil }
    let q = CGPoint(x: p.x, y: top - p.y)
    return onScreenWindows().first(where: { $0.frame.contains(q) })
}

func screenCaptureAllowed() -> Bool { CGPreflightScreenCaptureAccess() }

/// Jendela di level status bar (tiap ikon menu bar = satu jendela kecil)
func statusWindows() -> [(id: CGWindowID, frame: CGRect)] {
    let layer = Int(CGWindowLevelForKey(.statusWindow))
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == layer,
              let id = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let f = CGRect(dictionaryRepresentation: b as CFDictionary), f.width > 0, f.width < 1000 else { return nil }
        return (CGWindowID(id), f)
    }
}

/// Foto jendela ikon yang posisinya sama dengan frame Accessibility-nya (koordinat keduanya sama: kiri-atas)
func snapshot(_ f: CGRect, _ wins: [(id: CGWindowID, frame: CGRect)]) -> NSImage? {
    let mid = CGPoint(x: f.midX, y: f.midY)
    guard let w = wins.filter({ $0.frame.contains(mid) }).min(by: { $0.frame.width < $1.frame.width }) else { return nil }
    // utamakan CGSHWCaptureWindowList (bisa di luar layar); kalau tidak ada / gagal, pakai CGWindowListCreateImage
    var img = captureWindow(w.id)
    if img.map({ !hasContent($0) }) ?? true, let fn = windowImageFn {
        let opts = CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue
        img = fn(.null, CGWindowListOption.optionIncludingWindow.rawValue, w.id, opts)?.takeRetainedValue()
    }
    guard let cg = img, cg.width > 1, cg.height > 1, hasContent(cg) else { return nil }
    return NSImage(cgImage: cg, size: w.frame.size)
}

/// false kalau gambar kosong (transparan semua), mis. jendela ikon yang sedang di luar layar
func hasContent(_ cg: CGImage) -> Bool {
    let w = 32, h = 16
    // context tanpa buffer sendiri → CG yang mengelola memorinya (abu-abu + alpha)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 2,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let data = ctx.data else { return true }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
    for y in 0..<h {
        for x in 0..<w where px[y * ctx.bytesPerRow + x * 2 + 1] > 8 { return true }
    }
    return false
}

// MARK: - Strip scroller

/// Panel tanpa bingkai yang tetap bisa menerima keyboard (untuk tombol Esc)
final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Roda mouse vertikal → gulir horizontal (trackpad tetap bisa geser dua jari ke samping)
final class HScrollView: NSScrollView {
    override func scrollWheel(with e: NSEvent) {
        guard abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX), let doc = documentView else {
            return super.scrollWheel(with: e)
        }
        let step: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 14
        var o = contentView.bounds.origin
        o.x = min(max(o.x - e.scrollingDeltaY * step, 0), max(doc.frame.width - contentView.bounds.width, 0))
        contentView.scroll(to: o)
        reflectScrolledClipView(contentView)
    }
}

// MARK: - Gambar ikon

func symbol(_ name: String) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
    let img = NSImage(systemSymbolName: name, accessibilityDescription: "LiteScroller")?.withSymbolConfiguration(cfg)
    img?.isTemplate = true
    return img
}

/// Garis tipis "|" untuk pemisah saat terbuka
let dividerImage: NSImage = {
    let img = NSImage(size: NSSize(width: 6, height: 16), flipped: false) { r in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 2.25, y: 1, width: 1.5, height: r.height - 2), xRadius: 0.75, yRadius: 0.75).fill()
        return true
    }
    img.isTemplate = true // otomatis ikut warna menu bar (terang/gelap)
    return img
}()

// MARK: - Update (cek rilis terbaru di GitHub Releases)

final class Updater: NSObject {
    let repo = "kikiraihan/mac-os-lite-menu-bar-scroller"
    let appName = "LiteScroller"
    let menuItem = NSMenuItem(title: "Cek pembaruan…", action: #selector(Updater.checkNow), keyEquivalent: "")
    var latest: (version: String, zip: URL?, page: URL)?
    var timer: Timer?

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// "v1.2.0" lebih baru dari "1.1"?
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".")
                .map { part in Int(part.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    var hasUpdate: Bool { latest.map { Updater.isNewer($0.version, than: Updater.current) } ?? false }

    override init() {
        super.init()
        menuItem.target = self
    }

    /// Cek diam-diam saat aplikasi dibuka lalu sehari sekali; kalau ada versi baru, judul menu berubah
    func start() {
        check { [weak self] _ in self?.refreshMenu() }
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check { _ in self?.refreshMenu() }
        }
        t.tolerance = 3600 // tidak perlu tepat waktu → hemat energi
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refreshMenu() {
        menuItem.isEnabled = true
        if let l = latest, hasUpdate { menuItem.title = "Update tersedia: \(l.version)…" }
        else { menuItem.title = "Cek pembaruan…" }
    }

    /// Ambil info rilis terbaru; done(true) kalau berhasil (dipanggil di main thread)
    func check(_ done: @escaping (Bool) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return done(false) }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var info: (String, URL?, URL)?
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = j["tag_name"] as? String,
               let page = (j["html_url"] as? String).flatMap({ URL(string: $0) }) {
                let assets = j["assets"] as? [[String: Any]] ?? []
                let zip = assets.first { ($0["name"] as? String) == "\(self.appName).zip" }?["browser_download_url"] as? String
                info = (tag, zip.flatMap { URL(string: $0) }, page)
            }
            DispatchQueue.main.async {
                if let info { self.latest = (info.0, info.1, info.2) }
                done(info != nil)
            }
        }.resume()
    }

    @objc func checkNow() {
        menuItem.title = "Mengecek pembaruan…"
        menuItem.isEnabled = false
        check { [weak self] ok in
            guard let self else { return }
            self.refreshMenu()
            let a = NSAlert()
            NSApp.activate(ignoringOtherApps: true)
            guard ok, let l = self.latest else {
                a.messageText = "Gagal mengecek pembaruan"
                a.informativeText = "Periksa koneksi internet, lalu coba lagi."
                a.runModal()
                return
            }
            guard self.hasUpdate else {
                a.messageText = "\(self.appName) sudah versi terbaru"
                a.informativeText = "Versi terpasang: \(Updater.current)"
                a.runModal()
                return
            }
            a.messageText = "\(self.appName) \(l.version) tersedia"
            a.informativeText = "Versi terpasang: \(Updater.current).\n\n\(self.appName) akan ditutup, diganti versi baru, lalu dibuka lagi. Pengaturan tetap tersimpan.\n\nSetelah update, izin Aksesibilitas (mode scroller) mungkin perlu diberikan ulang."
            a.addButton(withTitle: "Update sekarang")
            a.addButton(withTitle: "Lihat rilis")
            a.addButton(withTitle: "Nanti")
            switch a.runModal() {
            case .alertFirstButtonReturn: self.install(l)
            case .alertSecondButtonReturn: NSWorkspace.shared.open(l.page)
            default: break
            }
        }
    }

    /// Unduh .zip rilis, ekstrak, lalu ganti .app lama setelah aplikasi ini keluar
    func install(_ l: (version: String, zip: URL?, page: URL)) {
        let dest = Bundle.main.bundleURL
        // tanpa file .zip, bukan .app, atau folder tidak bisa ditulis → unduh manual dari halaman rilis
        guard let zip = l.zip, dest.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(l.page)
            return
        }
        menuItem.title = "Mengunduh \(l.version)…"
        menuItem.isEnabled = false
        URLSession.shared.downloadTask(with: zip) { tmp, _, err in
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("\(self.appName)-update-\(UUID().uuidString)")
            let zipFile = work.appendingPathComponent("update.zip")
            let newApp = work.appendingPathComponent("\(self.appName).app")
            var problem: String?
            if let tmp {
                do {
                    // file sementara dihapus setelah handler ini selesai → pindahkan sekarang
                    try fm.createDirectory(at: work, withIntermediateDirectories: true)
                    try fm.moveItem(at: tmp, to: zipFile)
                    let unzip = Process()
                    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    unzip.arguments = ["-x", "-k", zipFile.path, work.path]
                    try unzip.run()
                    unzip.waitUntilExit()
                    if unzip.terminationStatus != 0 || !fm.fileExists(atPath: newApp.path) {
                        problem = "File rilis tidak berisi \(self.appName).app."
                    }
                } catch { problem = error.localizedDescription }
            } else {
                problem = err?.localizedDescription ?? "Unduhan gagal."
            }
            DispatchQueue.main.async {
                if let problem { return self.fail(problem, l.page) }
                // skrip kecil: tunggu aplikasi ini keluar, tukar .app (lama dicadangkan dulu), lalu buka lagi
                let script = """
                while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
                if mv "$3" "$4"; then
                  if mv "$2" "$3"; then rm -rf "$4"; else mv "$4" "$3"; fi
                fi
                xattr -cr "$3" 2>/dev/null
                open "$3"
                """
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", script, "sh", String(getpid()), newApp.path, dest.path,
                               work.appendingPathComponent("old.app").path]
                do { try p.run() } catch { return self.fail(error.localizedDescription, l.page) }
                NSApp.terminate(nil)
            }
        }.resume()
    }

    func fail(_ msg: String, _ page: URL) {
        refreshMenu()
        let a = NSAlert()
        a.messageText = "Update gagal"
        a.informativeText = "\(msg)\n\nHalaman rilis akan dibuka supaya Anda bisa mengunduh manual."
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
        NSWorkspace.shared.open(page)
    }
}

// MARK: - Aplikasi

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // urutan pembuatan penting: item baru muncul di KIRI item yang sudah ada → pemisah di kiri tombol
    let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let sep = NSStatusBar.system.statusItem(withLength: 12)
    let menu = NSMenu()
    let d = UserDefaults.standard
    let updater = Updater()

    let collapsedLength: CGFloat = 10_000 // cukup panjang untuk mendorong ikon di kirinya keluar layar
    let dividerLength: CGFloat = 12
    var collapsed = true
    var collapseTimer: Timer?

    var scrollMode: Bool { d.string(forKey: "mode") == "scroll" }
    var dropdownMode: Bool { d.string(forKey: "mode") == "dropdown" }
    /// mode scroller & dropdown: ikon tetap tersembunyi, dijangkau lewat strip / daftar
    var listMode: Bool { scrollMode || dropdownMode }
    var overlayMode: Bool { d.string(forKey: "mode") == "overlay" }

    // mode buka-tutup timpa
    var overlayActive = false
    var overlayPrevApp: NSRunningApplication? // aplikasi yang aktif sebelum dibuka, diaktifkan lagi saat ditutup
    let overlayMenu = NSMenu() // menu bar kosong selama terbuka
    var overlayWindow: NSWindow? // jendela transparan kecil supaya macOS mau mengaktifkan LiteScroller
    var overlaySwitching = false // sedang memakai trik Dock → abaikan notifikasi ganti aplikasi
    var overlayMonitor: Any? // klik di luar menu bar selama terbuka → tutup
    var lastIconClick = Date.distantPast // klik terakhir di menu bar (ikon yang dibuka) atau di menu / popover-nya
    var iconApps: Set<pid_t> = [] // aplikasi yang ikonnya diklik selama terbuka; jendela / popover-nya tidak menutup

    // strip scroller
    var strip: StripPanel?
    var stripItems: [BarItem] = []
    var monitors: [Any] = []
    var loadingStrip = false
    var shotCache: [String: NSImage] = [:] // gambar ikon terakhir yang berhasil diambil
    let dropMenu = NSMenu() // daftar ikon tersembunyi (mode dropdown)

    // item pengaturan
    let modeToggleItem = NSMenuItem(title: "Mode buka-tutup", action: #selector(AppDelegate.setMode(_:)), keyEquivalent: "")
    let modeOverlayItem = NSMenuItem(title: "Mode buka-tutup timpa", action: #selector(AppDelegate.setMode(_:)), keyEquivalent: "")
    let modeScrollItem = NSMenuItem(title: "Mode scroller", action: #selector(AppDelegate.setMode(_:)), keyEquivalent: "")
    let modeDropdownItem = NSMenuItem(title: "Mode dropdown", action: #selector(AppDelegate.setMode(_:)), keyEquivalent: "")
    var delayItems: [NSMenuItem] = []
    let loginItem = NSMenuItem(title: "Buka saat login", action: #selector(AppDelegate.toggleLogin), keyEquivalent: "")
    let axItem = NSMenuItem(title: "Izin Aksesibilitas (untuk mode scroller & dropdown)…", action: #selector(AppDelegate.requestAccess), keyEquivalent: "")
    let screenItem = NSMenuItem(title: "Izin Rekam Layar (gambar ikon asli di strip)…", action: #selector(AppDelegate.requestScreen), keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        d.register(defaults: ["mode": "toggle", "autoCollapse": 10.0])
        toggle.autosaveName = "LiteScrollerToggle" // posisi ikon diingat
        sep.autosaveName = "LiteScrollerSeparator"

        if let b = toggle.button {
            b.target = self
            b.action = #selector(toggleClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        if let b = sep.button {
            b.target = self
            b.action = #selector(separatorClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.toolTip = "Pemisah LiteScroller — ikon di kiri garis ini yang disembunyikan"
        }
        buildMenu()

        // tampil terbuka dulu sebentar supaya posisi pemisah terlihat, lalu tutup
        setCollapsed(false)
        scheduleCollapse(3)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appSwitched), name: NSWorkspace.didActivateApplicationNotification, object: nil)

        updater.start()

        if !d.bool(forKey: "didOnboard") {
            d.set(true, forKey: "didOnboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showHelp() }
        }
    }

    // MARK: buka-tutup

    /// true kalau pemisah ada di kiri tombol (kalau tertukar, jangan sembunyikan apa pun —
    /// tombolnya sendiri bisa ikut terdorong keluar layar)
    func separatorIsLeft() -> Bool {
        guard let s = sep.button?.window?.frame, let t = toggle.button?.window?.frame else { return true }
        return s.minX < t.minX
    }

    func setCollapsed(_ c: Bool) {
        collapseTimer?.invalidate()
        collapsed = c && separatorIsLeft()
        if c {
            endOverlay(restore: true)
            if let m = overlayMonitor { NSEvent.removeMonitor(m) }
            overlayMonitor = nil
            iconApps.removeAll()
        }
        sep.length = collapsed ? collapsedLength : dividerLength
        sep.button?.image = collapsed ? nil : dividerImage
        updateToggleIcon()
        if !collapsed {
            // tunggu menu bar selesai menata ulang ikon
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refreshShotCache() }
        }
    }

    /// Mode buka-tutup timpa: LiteScroller jadi aplikasi aktif sementara dengan menu bar kosong,
    /// jadi menu teks aplikasi lain (File, Edit, ...) hilang dan ruangnya dipakai ikon yang dibuka.
    /// Ikon yang tampil tetap ikon asli (bukan gambar seperti di mode scroller).
    func beginOverlay() {
        if !overlayActive {
            let front = NSWorkspace.shared.frontmostApplication
            overlayPrevApp = front?.processIdentifier == getpid() ? nil : front
            overlayActive = true
        }
        if overlayMonitor == nil {
            // keluar fokus (klik jendela / desktop lain) → tutup lagi, supaya ikon tidak tertimpa menu teks aplikasi itu.
            // Klik di menu bar (ikon yang baru terlihat) dibiarkan, begitu juga klik di jendela / popover yang dibuka
            // ikon itu (kalau ditutup, ikonnya terdorong keluar layar dan jendelanya ikut hilang / tidak bisa diklik).
            // Monitor tetap jalan sampai tertutup, walau menu bar sudah diambil aplikasi ikon itu.
            let dockLayer = Int(CGWindowLevelForKey(.dockWindow)) // klik Dock = pindah aplikasi, tetap menutup
            overlayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                guard let self, !self.collapsed else { return }
                let p = NSEvent.mouseLocation
                let hit = windowAt(p)
                if isInMenuBar(p) {
                    self.lastIconClick = Date()
                    if let hit, hit.pid != getpid() { self.iconApps.insert(hit.pid) }
                } else if let hit, (hit.layer > 0 && hit.layer != dockLayer) || self.iconApps.contains(hit.pid) {
                    // menu / popover / panel yang muncul dari ikon (level di atas jendela biasa; pemilik ikon di menu bar
                    // tidak selalu terbaca benar), atau jendela milik aplikasi ikon itu → biarkan terbuka. Kalau ditutup,
                    // ikonnya terdorong keluar layar dan menunya hilang sebelum pilihan yang diklik dijalankan.
                    self.lastIconClick = Date()
                    if hit.pid != getpid() { self.iconApps.insert(hit.pid) }
                } else {
                    self.endOverlay(restore: false) // jendela yang diklik yang jadi aktif, bukan aplikasi sebelumnya
                    self.setCollapsed(true)
                }
            }
        }
        NSApp.setActivationPolicy(.regular) // aplikasi .accessory tidak memegang menu bar
        if overlayMenu.items.isEmpty {
            // satu menu aplikasi kosong (tampil sebagai "LiteScroller"); menu utama yang benar-benar kosong
            // kadang membuat macOS tetap menampilkan menu aplikasi sebelumnya
            let appItem = NSMenuItem(title: "LiteScroller", action: nil, keyEquivalent: "")
            appItem.submenu = NSMenu(title: "LiteScroller")
            overlayMenu.addItem(appItem)
        }
        NSApp.mainMenu = overlayMenu
        // kebijakan .regular baru berlaku di putaran run loop berikutnya → aktifkan sesudahnya
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.activateOverlay(retry: true) }
    }

    func activateOverlay(retry: Bool) {
        guard overlayActive else { return }
        // jendela transparan 1×1 yang jadi key window: macOS lebih mau mengaktifkan aplikasi yang punya jendela
        let w = overlayWindow ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless],
                             backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            return w
        }()
        overlayWindow = w
        w.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.overlayActive else { return }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            NSLog("LiteScroller timpa: aplikasi aktif = \(front.map(String.init) ?? "-"), LiteScroller = \(getpid())")
            guard front != getpid(), retry else { return }
            // belum berhasil: trik yang umum dipakai — aktifkan Dock sebentar, lalu LiteScroller lagi
            self.overlaySwitching = true
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.activateOverlay(retry: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.overlaySwitching = false }
            }
        }
    }

    /// Kembalikan menu bar ke aplikasi sebelumnya (restore = false kalau pengguna sudah pindah aplikasi sendiri)
    func endOverlay(restore: Bool) {
        guard overlayActive else { return }
        overlayActive = false
        overlaySwitching = false
        overlayWindow?.orderOut(nil)
        let prev = overlayPrevApp
        overlayPrevApp = nil
        if restore && NSApp.isActive {
            if let prev, !prev.isTerminated { prev.activate(options: []) }
            else { NSApp.hide(nil) } // aplikasi sebelumnya sudah tidak ada → biar macOS memilih aplikasi berikutnya
        }
        NSApp.setActivationPolicy(.accessory) // tanpa ikon di Dock lagi
    }

    func updateToggleIcon() {
        let name: String
        if scrollMode { name = strip?.isVisible == true ? "chevron.right.2" : "chevron.left.2" }
        else if dropdownMode { name = "chevron.down" }
        else { name = collapsed ? "chevron.left" : "chevron.right" }
        toggle.button?.image = symbol(name)
    }

    /// Tutup otomatis setelah beberapa detik (0 = tidak pernah)
    func scheduleCollapse(_ secs: Double? = nil) {
        collapseTimer?.invalidate()
        let s = secs ?? d.double(forKey: "autoCollapse")
        guard s > 0 else { return }
        let t = Timer(timeInterval: s, repeats: false) { [weak self] _ in
            guard let self else { return }
            // jendela / popover ikon yang dibuka masih tampil → tunda, supaya tidak ikut hilang
            if self.iconAppWindowOpen() { return self.scheduleCollapse(2) }
            self.setCollapsed(true)
        }
        RunLoop.main.add(t, forMode: .common)
        collapseTimer = t
    }

    /// true kalau ada menu yang sedang terbuka, atau aplikasi yang ikonnya diklik masih punya jendela terlihat
    /// di luar menu bar
    func iconAppWindowOpen() -> Bool {
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        let menuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let bar = NSStatusBar.system.thickness + 2
        return onScreenWindows().contains { w in
            w.pid != getpid() && w.frame.maxY > bar
                && (w.layer == menuLayer || (iconApps.contains(w.pid) && w.layer != statusLayer))
        }
    }

    @objc func toggleClicked() {
        if let e = NSApp.currentEvent, e.type == .rightMouseUp || e.modifierFlags.contains(.option) {
            return showMenu()
        }
        if scrollMode {
            if strip?.isVisible == true { hideStrip() } else { showStrip() }
        } else if dropdownMode {
            showDropdown()
        } else {
            setCollapsed(!collapsed)
            if !collapsed {
                if overlayMode { beginOverlay() }
                scheduleCollapse()
            }
        }
    }

    @objc func separatorClicked() { showMenu() }

    // MARK: strip scroller

    func showStrip() {
        loadHidden { [weak self] items in self?.presentStrip(items) }
    }

    /// Baca ikon tersembunyi (di kiri pemisah) lalu panggil done di main thread;
    /// done(nil) kalau belum ada izin Aksesibilitas
    func loadHidden(_ done: @escaping ([BarItem]?) -> Void) {
        guard !loadingStrip else { return }
        guard axTrusted(prompt: false) else { return done(nil) }
        guard let tWin = toggle.button?.window, let sWin = sep.button?.window else { return }
        loadingStrip = true
        // pemisah TIDAK dibuka (supaya menu bar tidak berkedip ke mode buka-tutup): saat tertutup pemisah
        // memanjang ke kiri, jadi ikon tersembunyi = ikon di kiri ujung kiri pemisah (walau di luar layar).
        // Ikon di antara pemisah & tombol tetap terlihat di menu bar.
        let limit = separatorIsLeft() ? sWin.frame.minX : tWin.frame.minX
        scanItems(limit: limit) { [weak self] items in
            self?.loadingStrip = false
            done(items)
        }
    }

    /// Baca ikon di kiri `limit` (di background) + gambarnya; gambar yang gagal diambil
    /// (mis. ikon sedang di luar layar) diganti gambar terakhir dari cache
    func scanItems(limit: CGFloat, _ done: @escaping ([BarItem]) -> Void) {
        let capture = screenCaptureAllowed()
        DispatchQueue.global(qos: .userInitiated).async {
            var items = barItems().filter { $0.frame.midX < limit }
            if capture {
                let wins = statusWindows()
                for i in items.indices { items[i].shot = snapshot(items[i].frame, wins) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for i in items.indices {
                    if let shot = items[i].shot { self.shotCache[items[i].key] = shot }
                    else { items[i].shot = self.shotCache[items[i].key] }
                }
                done(items)
            }
        }
    }

    /// Saat pemisah terbuka (ikon tampil di menu bar), simpan gambar ikon ke cache untuk strip / dropdown
    func refreshShotCache() {
        guard listMode, !collapsed, !loadingStrip, axTrusted(prompt: false), screenCaptureAllowed(),
              let sWin = sep.button?.window, separatorIsLeft() else { return }
        scanItems(limit: sWin.frame.minX) { _ in }
    }

    /// items == nil → belum ada izin Aksesibilitas
    func presentStrip(_ items: [BarItem]?) {
        guard let tWin = toggle.button?.window, let sWin = sep.button?.window,
              let screen = tWin.screen ?? NSScreen.main else { return }
        // ikon tetap disembunyikan di menu bar; strip menampilkannya di atas menu bar
        setCollapsed(true)

        // tepi kanan strip = ujung kanan pemisah (ikon di antara pemisah & tombol tetap terlihat)
        let right = separatorIsLeft() ? min(sWin.frame.maxX, tWin.frame.minX) : tWin.frame.minX
        var left = screen.frame.minX
        if let r = screen.auxiliaryTopRightArea { left = max(left, r.minX) } // jangan masuk ke bawah notch

        let panel = strip ?? makeStrip()
        strip = panel
        let content = fillStrip(panel, items)
        // strip selebar isinya saja (rata kanan ke pemisah), kalau tidak muat baru bisa digulir
        let width = min(max(content, 120), max(right - left, 120))
        panel.setFrame(NSRect(x: right - width, y: tWin.frame.minY, width: width, height: tWin.frame.height), display: true)
        scrollToEnd(panel)
        panel.orderFrontRegardless()
        updateToggleIcon()

        // tutup strip: klik di luar, Esc, atau ganti aplikasi
        if monitors.isEmpty {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
                self?.hideStrip()
            }) { monitors.append(m) }
            if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
                if e.keyCode == 53 { self?.hideStrip() }
            }) { monitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
                if e.keyCode == 53 { self?.hideStrip(); return nil }
                return e
            }) { monitors.append(m) }
        }
    }

    // MARK: dropdown

    func showDropdown() {
        loadHidden { [weak self] items in self?.presentDropdown(items) }
    }

    /// Daftar ikon tersembunyi sebagai menu di bawah tombol; items == nil → belum ada izin Aksesibilitas
    func presentDropdown(_ items: [BarItem]?) {
        setCollapsed(true) // ikon tetap disembunyikan di menu bar
        dropMenu.removeAllItems()
        dropMenu.autoenablesItems = false
        dropMenu.delegate = self
        stripItems = items ?? []

        if items == nil {
            let it = NSMenuItem(title: "Butuh izin Aksesibilitas — klik untuk membuka Pengaturan",
                                action: #selector(requestAccess), keyEquivalent: "")
            it.target = self
            dropMenu.addItem(it)
        } else if stripItems.isEmpty {
            let it = NSMenuItem(title: "Belum ada ikon tersembunyi. Tahan ⌘ lalu seret ikon ke kiri pemisah |",
                                action: nil, keyEquivalent: "")
            it.isEnabled = false
            dropMenu.addItem(it)
        }
        // urutan dari kanan (terdekat ke pemisah) ke kiri, sama seperti strip yang mulai dari kanan
        for (i, it) in stripItems.enumerated().reversed() {
            // nama aplikasi lebih jelas dari judul item (judul bisa berisi nama akun / angka badge)
            let name = it.appName ?? it.label
            let title = name.count > 40 ? String(name.prefix(39)) + "…" : name
            let m = NSMenuItem(title: title, action: #selector(pressItem(_:)), keyEquivalent: "")
            m.target = self
            m.tag = i
            m.toolTip = it.label
            if let img = it.shot {
                // gambar asli ikon diperkecil ke tinggi baris menu
                let h: CGFloat = 18
                let copy = img.copy() as? NSImage
                copy?.size = NSSize(width: img.size.width * h / max(img.size.height, 1), height: h)
                m.image = copy
            } else {
                m.image = it.icon
            }
            dropMenu.addItem(m)
        }

        // pasang menu sebentar supaya muncul di bawah tombol, lalu lepas lagi (klik kiri tetap jadi aksi)
        toggle.menu = dropMenu
        toggle.button?.performClick(nil)
    }

    func hideStrip() {
        strip?.orderOut(nil)
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        updateToggleIcon()
    }

    @objc func appSwitched(_ n: Notification) {
        if strip?.isVisible == true { hideStrip() }
        // pengguna pindah ke aplikasi lain saat mode timpa terbuka → jangan rebut fokusnya lagi, dan tutup
        // (kalau tetap terbuka, ikonnya tertimpa menu teks aplikasi itu). Kecuali aplikasi itu aktif karena
        // ikonnya di menu bar baru diklik: biarkan terbuka supaya menu / popover-nya tetap di tempat.
        if overlayActive, !overlaySwitching, let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           a.processIdentifier != getpid() {
            endOverlay(restore: false)
            if Date().timeIntervalSince(lastIconClick) <= 2 {
                iconApps.insert(a.processIdentifier) // aktif karena pilihan di menu ikonnya (mis. buka jendela pengaturan)
            } else if !iconApps.contains(a.processIdentifier) {
                setCollapsed(true)
            }
        }
    }

    func makeStrip() -> StripPanel {
        let p = StripPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1) // di atas menu bar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        let fx = NSVisualEffectView()
        fx.material = .menu
        fx.blendingMode = .behindWindow
        fx.state = .active
        p.contentView = fx
        return p
    }

    /// Isi strip; mengembalikan lebar isi yang dibutuhkan
    func fillStrip(_ panel: StripPanel, _ items: [BarItem]?) -> CGFloat {
        guard let fx = panel.contentView else { return 0 }
        fx.subviews.forEach { $0.removeFromSuperview() }

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 2)

        stripItems = items ?? []
        if items == nil {
            let b = NSButton(title: "LiteScroller butuh izin Aksesibilitas untuk mode scroller — klik untuk membuka Pengaturan",
                             target: self, action: #selector(requestAccess))
            styleStripButton(b)
            stack.addView(b, in: .trailing)
        } else {
            if stripItems.isEmpty {
                let l = NSTextField(labelWithString: "Belum ada ikon tersembunyi. Tahan ⌘ lalu seret ikon ke kiri pemisah |")
                l.font = NSFont.menuBarFont(ofSize: 0)
                l.textColor = .secondaryLabelColor
                stack.addView(l, in: .trailing)
            }
            for (i, it) in stripItems.enumerated() {
                let b: NSButton
                if let img = it.shot ?? it.icon {
                    // gambar asli ikon (atau ikon aplikasinya) saja, tanpa teks — seperti di menu bar
                    b = NSButton(image: img, target: self, action: #selector(pressItem(_:)))
                    b.imagePosition = .imageOnly
                } else {
                    let title = it.label.count > 24 ? String(it.label.prefix(23)) + "…" : it.label
                    b = NSButton(title: title, target: self, action: #selector(pressItem(_:)))
                }
                b.tag = i
                b.toolTip = it.label
                styleStripButton(b)
                if it.shot != nil {
                    // lebar sama dengan ikon aslinya, jadi jaraknya sama seperti di menu bar
                    b.isBordered = false
                    b.widthAnchor.constraint(equalToConstant: it.frame.width).isActive = true
                } else if it.icon != nil {
                    b.isBordered = false
                    b.widthAnchor.constraint(equalToConstant: 28).isActive = true
                }
                stack.addView(b, in: .trailing)
            }
        }

        // isi strip rata kanan (dekat pemisah), seperti urutan asli di menu bar
        let size = panel.frame.size
        let fit = stack.fittingSize
        let height = toggle.button?.window?.frame.height ?? size.height
        let scroll = HScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        stack.frame = NSRect(x: 0, y: 0, width: fit.width, height: height)
        scroll.documentView = stack
        fx.addSubview(scroll)
        return fit.width
    }

    /// Mulai dari ujung kanan: ikon terdekat ke pemisah terlihat dulu, gulir ke kiri untuk yang lain
    func scrollToEnd(_ panel: StripPanel) {
        guard let fx = panel.contentView, let scroll = fx.subviews.first as? NSScrollView,
              let doc = scroll.documentView else { return }
        scroll.frame = fx.bounds
        let w = fx.bounds.width
        // kalau isi lebih sempit dari strip (lebar minimal), isi tetap rata kanan (gravity .trailing)
        doc.frame = NSRect(x: 0, y: 0, width: max(doc.frame.width, w), height: fx.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: max(doc.frame.width - w, 0), y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func styleStripButton(_ b: NSButton) {
        b.bezelStyle = .recessed
        b.showsBorderOnlyWhileMouseInside = true // sorotan hanya saat kursor di atasnya
        b.font = NSFont.menuBarFont(ofSize: 0)
        b.lineBreakMode = .byTruncatingTail
    }

    /// Klik ikon di strip / dropdown → buka sementara lalu "tekan" ikon aslinya lewat Accessibility
    @objc func pressItem(_ sender: AnyObject) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSButton)?.tag ?? -1
        guard tag >= 0, tag < stripItems.count else { return }
        let el = stripItems[tag].el
        hideStrip()
        setCollapsed(false) // supaya menu/popover milik ikon itu muncul di posisi yang terlihat
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            // AXPress bisa menunggu sampai menu aplikasi itu ditutup → jangan di main thread
            DispatchQueue.global(qos: .userInitiated).async {
                AXUIElementSetMessagingTimeout(el, 1)
                _ = AXUIElementPerformAction(el, "AXPress" as CFString)
            }
            guard let self else { return }
            let s = self.d.double(forKey: "autoCollapse")
            self.scheduleCollapse(s > 0 ? max(s, 10) : 15) // mode scroller & dropdown selalu kembali tertutup
        }
    }

    // MARK: menu pengaturan

    func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        let head = NSMenuItem(title: "LiteScroller", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        modeToggleItem.target = self
        modeToggleItem.representedObject = "toggle"
        menu.addItem(modeToggleItem)
        modeOverlayItem.target = self
        modeOverlayItem.representedObject = "overlay"
        menu.addItem(modeOverlayItem)
        modeScrollItem.target = self
        modeScrollItem.representedObject = "scroll"
        menu.addItem(modeScrollItem)
        modeDropdownItem.target = self
        modeDropdownItem.representedObject = "dropdown"
        menu.addItem(modeDropdownItem)
        menu.addItem(.separator())

        // submenu: tutup otomatis
        let delayMenu = NSMenu()
        for (s, title) in [(0.0, "Tidak pernah"), (5.0, "5 detik"), (10.0, "10 detik"), (30.0, "30 detik"), (60.0, "1 menit")] {
            let it = NSMenuItem(title: title, action: #selector(setDelay(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = s
            delayMenu.addItem(it)
            delayItems.append(it)
        }
        let delayItem = NSMenuItem(title: "Tutup otomatis", action: nil, keyEquivalent: "")
        delayItem.submenu = delayMenu
        menu.addItem(delayItem)

        loginItem.target = self
        menu.addItem(loginItem)
        axItem.target = self
        menu.addItem(axItem)
        screenItem.target = self
        menu.addItem(screenItem)
        menu.addItem(.separator())

        let help = NSMenuItem(title: "Cara pakai…", action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        menu.addItem(updater.menuItem)
        let un = NSMenuItem(title: "Uninstall LiteScroller…", action: #selector(uninstall), keyEquivalent: "")
        un.target = self
        menu.addItem(un)
        menu.addItem(NSMenuItem(title: "Keluar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func showMenu() {
        hideStrip()
        updateChecks()
        // pasang menu sebentar supaya muncul di bawah tombol, lalu lepas lagi (klik kiri tetap jadi aksi)
        toggle.menu = menu
        toggle.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) { toggle.menu = nil }

    func updateChecks() {
        modeToggleItem.state = listMode || overlayMode ? .off : .on
        modeOverlayItem.state = overlayMode ? .on : .off
        modeScrollItem.state = scrollMode ? .on : .off
        modeDropdownItem.state = dropdownMode ? .on : .off
        let cur = d.double(forKey: "autoCollapse")
        for it in delayItems { it.state = (it.representedObject as? Double) == cur ? .on : .off }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        axItem.state = axTrusted(prompt: false) ? .on : .off
        screenItem.state = screenCaptureAllowed() ? .on : .off
    }

    // MARK: aksi

    @objc func setMode(_ s: NSMenuItem) {
        guard let m = s.representedObject as? String else { return }
        d.set(m, forKey: "mode")
        hideStrip()
        setCollapsed(true)
        if listMode && !axTrusted(prompt: false) { requestAccess() } // buka-tutup & buka-tutup timpa tanpa izin
    }
    @objc func setDelay(_ s: NSMenuItem) {
        guard let v = s.representedObject as? Double else { return }
        d.set(v, forKey: "autoCollapse")
        if !collapsed && !listMode { scheduleCollapse() }
    }
    @objc func requestAccess() {
        hideStrip()
        if !axTrusted(prompt: true),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    /// Opsional: tanpa izin ini strip menampilkan ikon aplikasi / nama item, bukan gambar asli ikonnya
    @objc func requestScreen() {
        hideStrip()
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Gagal mengatur 'Buka saat login'"
            a.informativeText = "Pastikan LiteScroller.app ada di folder Applications.\n\n\(error.localizedDescription)"
            a.runModal()
        }
        updateChecks()
    }
    @objc func showHelp() {
        setCollapsed(false) // tampilkan pemisah supaya mudah ditemukan
        let a = NSAlert()
        a.messageText = "Cara pakai LiteScroller"
        a.informativeText = """
        Di menu bar ada dua item baru:  |  (pemisah) dan  ‹  (tombol).

        1. Tahan ⌘ lalu seret ikon yang ingin disembunyikan ke KIRI pemisah |.
           Ikon di antara | dan ‹ selalu terlihat.
        2. Klik ‹ untuk membuka / menutup.
        3. Klik kanan ‹ (atau klik |) untuk pengaturan.

        Mode buka-tutup: ikon di kiri | muncul / hilang langsung di menu bar.
        Mode buka-tutup timpa: sama, tapi saat terbuka menu teks aplikasi (File, Edit, ...) \
        disembunyikan sementara supaya ikon punya ruang. Menu kembali saat ditutup.
        Mode scroller: klik ‹ menampilkan strip di atas menu bar berisi semua ikon tersembunyi. \
        Gulir dengan trackpad atau roda mouse, lalu klik ikon untuk membukanya. Cocok kalau \
        menu aplikasi terlalu panjang atau ada notch, sehingga sebagian ikon tetap tertutup. \
        Mode dropdown: klik ⌄ menampilkan daftar semua ikon tersembunyi sebagai menu di bawah tombol. \
        Mode scroller & dropdown butuh izin Aksesibilitas. Beri juga izin Rekam Layar (opsional) \
        supaya strip / daftar menampilkan gambar asli ikon, sama seperti di menu bar.
        """
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
        scheduleCollapse()
    }

    /// Hapus LiteScroller dari Mac: login item, izin Aksesibilitas, pengaturan, lalu .app dipindahkan ke Tong Sampah
    @objc func uninstall() {
        hideStrip()
        let a = NSAlert()
        a.messageText = "Uninstall LiteScroller?"
        a.informativeText = "Ikon yang tersembunyi akan tampil lagi. LiteScroller dihapus dari 'Buka saat login' dan daftar izin Aksesibilitas & Rekam Layar, pengaturannya dihapus, lalu LiteScroller.app dipindahkan ke Tong Sampah dan aplikasi ditutup."
        a.alertStyle = .warning
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Batal")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        setCollapsed(false) // kembalikan ikon yang disembunyikan
        try? SMAppService.mainApp.unregister()
        if let id = Bundle.main.bundleIdentifier {
            // cabut izin Aksesibilitas (dan Rekam Layar) supaya tidak tertinggal di Pengaturan Sistem
            for service in ["Accessibility", "ScreenCapture"] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                p.arguments = ["reset", service, id]
                try? p.run()
                p.waitUntilExit()
            }
            d.removePersistentDomain(forName: id)
            d.synchronize()
        }
        let appURL = Bundle.main.bundleURL
        if appURL.pathExtension != "app" || (try? FileManager.default.trashItem(at: appURL, resultingItemURL: nil)) == nil {
            // tidak punya izin tulis (mis. dipasang oleh admin lain) → minta pengguna menghapus manual
            let f = NSAlert()
            f.messageText = "LiteScroller.app tidak bisa dipindahkan otomatis"
            f.informativeText = "Pengaturan sudah dihapus. Seret LiteScroller.app ke Tong Sampah secara manual."
            f.runModal()
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        }
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // tanpa ikon di Dock
app.run()
