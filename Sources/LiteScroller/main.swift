// LiteScroller — pemisah (separator) menu bar macOS dengan dua mode:
//   • Buka-tutup : ikon di kiri pemisah disembunyikan / ditampilkan (seperti Hidden Bar)
//   • Scroller   : ikon tersembunyi ditampilkan di strip yang bisa digulir, jadi tetap
//                  terjangkau walau menu aplikasi (teks di kiri) terlalu panjang / ada notch
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
struct BarItem { let el: AXUIElement; let frame: CGRect; let label: String; let icon: NSImage? }

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
    var pids = statusItemPIDs()
    if pids.isEmpty { pids = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier }) }
    pids.remove(getpid())
    var out: [BarItem] = []
    for pid in pids {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.3) // aplikasi yang macet tidak ikut membuat kita macet
        guard let bar = axAttr(appEl, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let kids = axAttr(bar as! AXUIElement, "AXChildren") as? [AXUIElement] else { continue }
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
            out.append(BarItem(el: k, frame: f, label: label, icon: icon))
        }
    }
    return out.sorted { $0.frame.minX < $1.frame.minX }
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

    // strip scroller
    var strip: StripPanel?
    var stripItems: [BarItem] = []
    var monitors: [Any] = []

    // item pengaturan
    let modeToggleItem = NSMenuItem(title: "Mode buka-tutup", action: #selector(AppDelegate.setMode(_:)), keyEquivalent: "")
    let modeScrollItem = NSMenuItem(title: "Mode scroller", action: #selector(AppDelegate.setMode(_:)), keyEquivalent: "")
    var delayItems: [NSMenuItem] = []
    let loginItem = NSMenuItem(title: "Buka saat login", action: #selector(AppDelegate.toggleLogin), keyEquivalent: "")
    let axItem = NSMenuItem(title: "Izin Aksesibilitas (untuk mode scroller)…", action: #selector(AppDelegate.requestAccess), keyEquivalent: "")

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
        sep.length = collapsed ? collapsedLength : dividerLength
        sep.button?.image = collapsed ? nil : dividerImage
        updateToggleIcon()
    }

    func updateToggleIcon() {
        let name: String
        if scrollMode { name = strip?.isVisible == true ? "chevron.right.2" : "chevron.left.2" }
        else { name = collapsed ? "chevron.left" : "chevron.right" }
        toggle.button?.image = symbol(name)
    }

    /// Tutup otomatis setelah beberapa detik (0 = tidak pernah)
    func scheduleCollapse(_ secs: Double? = nil) {
        collapseTimer?.invalidate()
        let s = secs ?? d.double(forKey: "autoCollapse")
        guard s > 0 else { return }
        let t = Timer(timeInterval: s, repeats: false) { [weak self] _ in self?.setCollapsed(true) }
        RunLoop.main.add(t, forMode: .common)
        collapseTimer = t
    }

    @objc func toggleClicked() {
        if let e = NSApp.currentEvent, e.type == .rightMouseUp || e.modifierFlags.contains(.option) {
            return showMenu()
        }
        if scrollMode {
            if strip?.isVisible == true { hideStrip() } else { showStrip() }
        } else {
            setCollapsed(!collapsed)
            if !collapsed { scheduleCollapse() }
        }
    }

    @objc func separatorClicked() { showMenu() }

    // MARK: strip scroller

    func showStrip() {
        guard let tWin = toggle.button?.window, let sWin = sep.button?.window,
              let screen = tWin.screen ?? NSScreen.main else { return }
        // ikon tetap disembunyikan di menu bar; strip menampilkannya di atas menu bar
        if !collapsed { setCollapsed(true) }

        // tepi kanan strip = ujung kanan pemisah (ikon di antara pemisah & tombol tetap terlihat)
        let right = separatorIsLeft() ? min(sWin.frame.maxX, tWin.frame.minX) : tWin.frame.minX
        var left = screen.frame.minX
        if let r = screen.auxiliaryTopRightArea { left = max(left, r.minX) } // jangan masuk ke bawah notch
        let frame = NSRect(x: left, y: tWin.frame.minY, width: max(right - left, 120), height: tWin.frame.height)

        let panel = strip ?? makeStrip()
        strip = panel
        panel.setFrame(frame, display: false)
        fillStrip(panel)
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

    func hideStrip() {
        strip?.orderOut(nil)
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        updateToggleIcon()
    }

    @objc func appSwitched() {
        if strip?.isVisible == true { hideStrip() }
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

    func fillStrip(_ panel: StripPanel) {
        guard let fx = panel.contentView else { return }
        fx.subviews.forEach { $0.removeFromSuperview() }
        let size = panel.frame.size

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 4)

        stripItems = []
        if !axTrusted(prompt: false) {
            let b = NSButton(title: "LiteScroller butuh izin Aksesibilitas untuk mode scroller — klik untuk membuka Pengaturan",
                             target: self, action: #selector(requestAccess))
            styleStripButton(b)
            stack.addView(b, in: .trailing)
        } else {
            // ikon di kiri pemisah (pemisah sedang memanjang ke kiri, jadi pakai titik tengahnya)
            let sMid = sep.button?.window?.frame.midX ?? .greatestFiniteMagnitude
            stripItems = barItems().filter { $0.frame.midX < sMid }
            if stripItems.isEmpty {
                let l = NSTextField(labelWithString: "Belum ada ikon tersembunyi. Tahan ⌘ lalu seret ikon ke kiri pemisah |")
                l.font = NSFont.menuBarFont(ofSize: 0)
                l.textColor = .secondaryLabelColor
                stack.addView(l, in: .trailing)
            }
            for (i, it) in stripItems.enumerated() {
                let title = it.label.count > 24 ? String(it.label.prefix(23)) + "…" : it.label
                let b = NSButton(title: title, target: self, action: #selector(pressItem(_:)))
                b.tag = i
                b.toolTip = it.label
                if let ic = it.icon { b.image = ic; b.imagePosition = .imageLeading }
                styleStripButton(b)
                stack.addView(b, in: .trailing)
            }
        }

        // isi strip rata kanan (dekat pemisah), seperti urutan asli di menu bar
        let scroll = HScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        let fit = stack.fittingSize
        stack.frame = NSRect(x: 0, y: 0, width: max(fit.width, size.width), height: size.height)
        scroll.documentView = stack
        fx.addSubview(scroll)
        // mulai dari ujung kanan: ikon terdekat ke pemisah terlihat dulu, gulir ke kiri untuk yang lain
        scroll.contentView.scroll(to: NSPoint(x: max(stack.frame.width - size.width, 0), y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func styleStripButton(_ b: NSButton) {
        b.bezelStyle = .recessed
        b.showsBorderOnlyWhileMouseInside = true // sorotan hanya saat kursor di atasnya
        b.font = NSFont.menuBarFont(ofSize: 0)
        b.lineBreakMode = .byTruncatingTail
    }

    /// Klik ikon di strip → buka sementara lalu "tekan" ikon aslinya lewat Accessibility
    @objc func pressItem(_ b: NSButton) {
        guard b.tag < stripItems.count else { return }
        let el = stripItems[b.tag].el
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
            self.scheduleCollapse(s > 0 ? max(s, 10) : 15) // mode scroller selalu kembali tertutup
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
        modeScrollItem.target = self
        modeScrollItem.representedObject = "scroll"
        menu.addItem(modeScrollItem)
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
        modeToggleItem.state = scrollMode ? .off : .on
        modeScrollItem.state = scrollMode ? .on : .off
        let cur = d.double(forKey: "autoCollapse")
        for it in delayItems { it.state = (it.representedObject as? Double) == cur ? .on : .off }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        axItem.state = axTrusted(prompt: false) ? .on : .off
    }

    // MARK: aksi

    @objc func setMode(_ s: NSMenuItem) {
        guard let m = s.representedObject as? String else { return }
        d.set(m, forKey: "mode")
        hideStrip()
        setCollapsed(true)
        if m == "scroll" && !axTrusted(prompt: false) { requestAccess() }
    }
    @objc func setDelay(_ s: NSMenuItem) {
        guard let v = s.representedObject as? Double else { return }
        d.set(v, forKey: "autoCollapse")
        if !collapsed && !scrollMode { scheduleCollapse() }
    }
    @objc func requestAccess() {
        hideStrip()
        if !axTrusted(prompt: true),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
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
        Mode scroller: klik ‹ menampilkan strip di atas menu bar berisi semua ikon tersembunyi. \
        Gulir dengan trackpad atau roda mouse, lalu klik ikon untuk membukanya. Cocok kalau \
        menu aplikasi terlalu panjang atau ada notch, sehingga sebagian ikon tetap tertutup. \
        Mode ini butuh izin Aksesibilitas.
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
        a.informativeText = "Ikon yang tersembunyi akan tampil lagi. LiteScroller dihapus dari 'Buka saat login' dan daftar izin Aksesibilitas, pengaturannya dihapus, lalu LiteScroller.app dipindahkan ke Tong Sampah dan aplikasi ditutup."
        a.alertStyle = .warning
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Batal")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        setCollapsed(false) // kembalikan ikon yang disembunyikan
        try? SMAppService.mainApp.unregister()
        if let id = Bundle.main.bundleIdentifier {
            // cabut izin Aksesibilitas supaya tidak tertinggal di Pengaturan Sistem
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "Accessibility", id]
            try? p.run()
            p.waitUntilExit()
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
