import Cocoa
import IOKit.hid
import UniformTypeIdentifiers

// ---------- Veri ----------
struct Mapping: Codable { var device: String; var page: Int; var usage: Int; var k1: Int; var k2: Int?; var mouse: String?; var app: String?; var layer: Int? }

let modFlag: [Int: CGEventFlags] = [
    54: .maskCommand, 55: .maskCommand, 56: .maskShift, 60: .maskShift,
    58: .maskAlternate, 61: .maskAlternate, 59: .maskControl, 62: .maskControl, 63: .maskSecondaryFn]
let modNSFlag: [Int: NSEvent.ModifierFlags] = [
    54: .command, 55: .command, 56: .shift, 60: .shift,
    58: .option, 61: .option, 59: .control, 62: .control, 63: .function]

let names: [Int: String] = [
    0:"A",11:"B",8:"C",2:"D",14:"E",3:"F",5:"G",4:"H",34:"I",38:"J",40:"K",37:"L",46:"M",
    45:"N",31:"O",35:"P",12:"Q",15:"R",1:"S",17:"T",32:"U",9:"V",13:"W",7:"X",16:"Y",6:"Z",
    18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",29:"0",
    36:"Return",76:"Enter",53:"Esc",49:"Boşluk",48:"Tab",51:"Delete",117:"Sil (ileri)",
    123:"←",124:"→",125:"↓",126:"↑",115:"Home",119:"End",116:"PageUp",121:"PageDown",
    122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",
    55:"⌘ Command",54:"⌘ Command (sağ)",56:"⇧ Shift",60:"⇧ Shift (sağ)",
    58:"⌥ Option",61:"⌥ Option (sağ)",59:"⌃ Control",62:"⌃ Control (sağ)",63:"fn",
    43:",",47:".",44:"/",41:";",39:"'",33:"[",30:"]",42:"\\",27:"-",24:"=",50:"`"
]
func keyName(_ c: Int) -> String { names[c] ?? "Tuş#\(c)" }

let consumerNames: [Int: String] = [
    0x40:"Menü", 0x41:"Tamam (OK)", 0x42:"Yukarı", 0x43:"Aşağı", 0x44:"Sol", 0x45:"Sağ", 0x46:"Menü Çıkış",
    0x223:"Home", 0x224:"Geri", 0x30:"Güç", 0xE9:"Ses +", 0xEA:"Ses −", 0xE2:"Sessiz",
    0xCD:"Oynat/Duraklat", 0xB5:"Sonraki", 0xB6:"Önceki"
]
func sourceName(_ page: Int, _ usage: Int) -> String {
    if page == 0x0C, let n = consumerNames[usage] { return "\(n) (0x\(String(usage, radix: 16)))" }
    return "Tuş (sayfa 0x\(String(page, radix: 16)), kullanım 0x\(String(usage, radix: 16)))"
}

// ---------- Tuş gönderme ----------
// Ok/gezinme/F tuşları gerçek klavyede fn bayrağıyla gelir (Mission Control gibi kısayollar bunu bekler)
let fnKeys: Set<Int> = [123, 124, 125, 126, 115, 116, 117, 119, 121,
                        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

func postKey(_ code: Int, down: Bool, flags: CGEventFlags) {
    let src = CGEventSource(stateID: .hidSystemState)
    if modFlag[code] != nil {
        // Değiştirici tuşlar (⌘ ⇧ ⌥ ⌃ fn) gerçek klavyede "flagsChanged" olayıdır
        if let e = CGEvent(source: src) {
            e.type = .flagsChanged
            e.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
        return
    }
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down) else { return }
    var f = flags
    if fnKeys.contains(code) { f.insert(.maskSecondaryFn) }
    e.flags = f
    e.post(tap: .cghidEventTap)
}

func performMapping(_ m: Mapping) {
    let f: CGEventFlags = modFlag[m.k1] ?? []
    var steps: [() -> Void] = [{ postKey(m.k1, down: true, flags: f) }]
    if let k2 = m.k2 {
        steps.append { postKey(k2, down: true, flags: f) }
        steps.append { postKey(k2, down: false, flags: f) }
    }
    steps.append { postKey(m.k1, down: false, flags: []) }
    for (i, st) in steps.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012 * Double(i), execute: st)
    }
}

func openApp(_ path: String) {
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path),
                                       configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
}
func appName(_ path: String) -> String {
    URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
}

// ---------- Fare ----------
let mouseOptions: [(String, String)] = [
    ("", "Klavye tuşu"),
    ("left", "🖱 Sol tık"), ("right", "🖱 Sağ tık"), ("middle", "🖱 Orta tık"), ("double", "🖱 Çift tık"),
    ("scrollUp", "🖱 Tekerlek yukarı"), ("scrollDown", "🖱 Tekerlek aşağı"),
    ("videoNext", "📱 Sonraki video (aşağı kaydır)"), ("videoPrev", "📱 Önceki video (yukarı kaydır)"),
    ("moveUp", "🖱 İmleç yukarı"), ("moveDown", "🖱 İmleç aşağı"),
    ("moveLeft", "🖱 İmleç sola"), ("moveRight", "🖱 İmleç sağa"),
    ("app", "🚀 Uygulama aç")
]
var moveSpeed: Double = UserDefaults.standard.object(forKey: "moveSpeed") as? Double ?? 12
var holdTime: Double = UserDefaults.standard.object(forKey: "holdTime") as? Double ?? 0.3
var scrollSpeed: Double = UserDefaults.standard.object(forKey: "scrollSpeed") as? Double ?? 20
var swipeAmount: Double = UserDefaults.standard.object(forKey: "swipeAmount") as? Double ?? 500

func cursorPos() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

func clampToDisplays(_ p: CGPoint) -> CGPoint {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    var all = CGRect.null
    for i in 0..<Int(n) { all = all.union(CGDisplayBounds(ids[i])) }
    if all.isNull { return p }
    return CGPoint(x: min(max(p.x, all.minX), all.maxX - 1), y: min(max(p.y, all.minY), all.maxY - 1))
}

func moveCursor(dx: Double, dy: Double) {
    let old = cursorPos()
    let np = clampToDisplays(CGPoint(x: old.x + dx, y: old.y + dy))
    guard let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                          mouseType: .mouseMoved, mouseCursorPosition: np, mouseButton: .left) else { return }
    e.setIntegerValueField(.mouseEventDeltaX, value: Int64(np.x - old.x))
    e.setIntegerValueField(.mouseEventDeltaY, value: Int64(np.y - old.y))
    e.post(tap: .cghidEventTap)
}

func mouseClick(_ kind: String) {
    let p = cursorPos()
    let src = CGEventSource(stateID: .hidSystemState)
    var downT = CGEventType.leftMouseDown, upT = CGEventType.leftMouseUp, btn = CGMouseButton.left
    switch kind {
    case "right": downT = .rightMouseDown; upT = .rightMouseUp; btn = .right
    case "middle": downT = .otherMouseDown; upT = .otherMouseUp; btn = .center
    default: break
    }
    let times = (kind == "double") ? 2 : 1
    for i in 1...times {
        for t in [downT, upT] {
            if let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: btn) {
                e.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                e.post(tap: .cghidEventTap)
            }
        }
    }
}

func mouseScroll(_ amount: Int32) {
    CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .pixel,
            wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
}

// TikTok / Instagram Reels gibi videoları tek vuruşta kaydırır (bir basış = bir video)
var lastSwipe = Date.distantPast
func videoSwipe(next: Bool) {
    let now = Date()
    if now.timeIntervalSince(lastSwipe) < 0.45 { return } // animasyon bitmeden ikinci kaydırmayı yok say
    lastSwipe = now
    let steps = 8
    let per = Int32(max(1, swipeAmount / Double(steps)))
    for i in 0..<steps {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012 * Double(i)) {
            mouseScroll(next ? -per : per)
        }
    }
}

// Tuş basılı tutulduğu sürece imleci/tekerleği sürekli çalıştırır (kademeli hızlanma ile)
enum Hold {
    static var timer: Timer?
    static var heldKey = ""
    static var action = ""
    static var start = Date()
    static var last = Date()

    static func press(_ k: String, _ a: String) {
        if k == heldKey, timer != nil { last = Date(); return }
        stop()
        heldKey = k; action = a; start = Date(); last = Date()
        tick()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in Hold.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    static func release(_ k: String) { if k == heldKey { stop() } }
    static func stop() { timer?.invalidate(); timer = nil; heldKey = "" }

    static func tick() {
        let now = Date()
        if now.timeIntervalSince(last) > 3 { stop(); return } // bırakma sinyali kaçarsa güvenlik
        let f = 0.35 + 0.65 * min(1, now.timeIntervalSince(start) / 0.7)
        let v = max(1, moveSpeed * f)
        let sc = Int32(max(1, scrollSpeed * f))
        switch action {
        case "moveUp": moveCursor(dx: 0, dy: -v)
        case "moveDown": moveCursor(dx: 0, dy: v)
        case "moveLeft": moveCursor(dx: -v, dy: 0)
        case "moveRight": moveCursor(dx: v, dy: 0)
        case "scrollUp": mouseScroll(sc)
        case "scrollDown": mouseScroll(-sc)
        default: break
        }
    }
}

// ---------- Kumanda dinleme (HID) ----------
var onHID: ((String, Int, Int, Bool) -> Void)?
var onDevice: ((String) -> Void)?
var hidManager: IOHIDManager?
var activeBox: KeyBox?

func startHID() -> IOReturn {
    let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(hid, nil)
    IOHIDManagerRegisterInputValueCallback(hid, { _, _, _, value in
        let el = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(el))
        let usage = Int(IOHIDElementGetUsage(el))
        guard page == 0x07 || page == 0x0C, usage > 0, usage < 0xFFFF else { return }
        let isDown = IOHIDValueGetIntegerValue(value) != 0
        let dev = IOHIDElementGetDevice(el)
        let vendor = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        if vendor == 0x05AC || vendor == 0x004C { return } // Apple cihazları yok sayılır
        let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "Bilinmeyen"
        onHID?(name, page, usage, isDown)
    }, nil)
    IOHIDManagerRegisterDeviceMatchingCallback(hid, { _, _, _, dev in
        let vendor = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        if vendor == 0x05AC || vendor == 0x004C { return }
        let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "Bilinmeyen"
        onDevice?(name)
    }, nil)
    IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    let r = IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
    hidManager = hid
    return r
}

// ---------- Tuş kutusu ----------
final class KeyBox: NSButton {
    var code: Int? { didSet { refresh() } }
    var onChange: ((Int?) -> Void)?
    override init(frame f: NSRect) {
        super.init(frame: f)
        bezelStyle = .rounded
        target = self; action = #selector(begin)
        widthAnchor.constraint(equalToConstant: 130).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() { title = code.map { keyName($0) } ?? "boş – tıkla" }
    @objc func begin() { activeBox?.refresh(); activeBox = self; title = "Tuşa bas…" }
    func set(_ c: Int) { code = c; onChange?(c) }
}

// ---------- Satır ----------
final class Row {
    let device: String, page: Int, usage: Int
    let layer: Int
    var mouse: String?
    var appPath: String? { didSet { refreshAppTitle() } }
    let label: NSTextField
    let act = NSPopUpButton(frame: .zero, pullsDown: false)
    let appBtn = NSButton(title: "Uygulama seç…", target: nil, action: nil)
    let b1 = KeyBox(frame: .zero), b2 = KeyBox(frame: .zero)
    let plus = NSTextField(labelWithString: "+")
    let del = NSButton(title: "Sil", target: nil, action: nil)
    let view: NSStackView
    var key: String { "\(device)|\(page)|\(usage)|\(layer)" }
    var isEmpty: Bool { b1.code == nil && b2.code == nil && mouse == nil }

    init(device: String, page: Int, usage: Int, k1: Int?, k2: Int?, mouse: String? = nil, appPath: String? = nil, layer: Int = 0) {
        self.device = device; self.page = page; self.usage = usage; self.mouse = mouse; self.layer = layer
        label = NSTextField(labelWithString: "\(device) · \(sourceName(page, usage))")
        label.widthAnchor.constraint(equalToConstant: 190).isActive = true
        label.lineBreakMode = .byTruncatingTail
        b1.code = k1; b2.code = k2
        for o in mouseOptions { act.addItem(withTitle: o.1) }
        if let m = mouse, let i = mouseOptions.firstIndex(where: { $0.0 == m }) { act.selectItem(at: i) }
        act.widthAnchor.constraint(equalToConstant: 150).isActive = true
        appBtn.bezelStyle = .rounded
        appBtn.widthAnchor.constraint(equalToConstant: 270).isActive = true
        view = NSStackView(views: [label, act, appBtn, b1, plus, b2, del])
        view.spacing = 8
        self.appPath = appPath
        refreshAppTitle()
        updateVisibility()
    }
    func refreshAppTitle() { appBtn.title = appPath.map { "🚀 " + appName($0) } ?? "Uygulama seç…" }
    func updateVisibility() {
        let kb = (mouse == nil)
        b1.isHidden = !kb; plus.isHidden = !kb; b2.isHidden = !kb
        appBtn.isHidden = (mouse != "app")
    }
    func flash() {
        label.textColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.label.textColor = .labelColor }
    }
}

// ---------- Uygulama ----------
final class AppDelegate: NSObject, NSApplicationDelegate {
    var win: NSWindow!
    let perm = NSTextField(wrappingLabelWithString: "")
    let last = NSTextField(wrappingLabelWithString: "Atama kapalı. Yalnızca atanmış tuşlar çalışır.")
    let list = NSStackView()
    var rows: [Row] = []
    var table: [String: Mapping] = [:]
    var assigning = false
    var editLayer = 0
    var layerKey: String? = UserDefaults.standard.string(forKey: "layerKey")
    var layerActive = false, layerDown = false, layerFired = false, pickingLayer = false
    var layerTimer: Timer?
    let holdLbl = NSTextField(labelWithString: "")
    let profLbl = NSTextField(labelWithString: "Aktif profil: Profil 1")
    let layerBtn = NSButton(title: "Seç…", target: nil, action: nil)
    let layerClear = NSButton(title: "Kaldır", target: nil, action: nil)
    let seg = NSSegmentedControl(labels: ["Profil 1 (normal)", "Profil 2 (profil tuşuna uzun basınca)"],
                                 trackingMode: .selectOne, target: nil, action: nil)
    var hidErr: IOReturn = 0
    let moveLbl = NSTextField(labelWithString: "")
    let scrollLbl = NSTextField(labelWithString: "")
    let swipeLbl = NSTextField(labelWithString: "")
    let assignBtn = NSButton(title: "▶︎ Atamayı başlat", target: nil, action: nil)
    var statusItem: NSStatusItem!
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    var devices: [String] = []
    var selected: String? = UserDefaults.standard.string(forKey: "device")

    func addDevice(_ name: String) {
        guard !devices.contains(name) else { return }
        devices.append(name)
        popup.addItem(withTitle: name)
        if selected == nil && name.contains("Xiaomi") { selected = name; UserDefaults.standard.set(name, forKey: "device") }
        if name == selected { popup.selectItem(withTitle: name) }
        applyFilter()
    }

    @objc func deviceChanged() {
        selected = popup.indexOfSelectedItem == 0 ? nil : popup.titleOfSelectedItem
        UserDefaults.standard.set(selected, forKey: "device")
        applyFilter()
    }

    func applyFilter() {
        for r in rows { r.view.isHidden = (selected != nil && r.device != selected) || r.layer != editLayer }
    }

    func clearEmpty() {
        for r in rows where r.isEmpty {
            list.removeArrangedSubview(r.view); r.view.removeFromSuperview()
        }
        rows.removeAll { $0.isEmpty }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }

        let hint = NSTextField(wrappingLabelWithString:
            "1) “Atamayı başlat”a bas, kumandada bir tuşa bas: satırı belirir.\n" +
            "2) Klavye tuşu için kutulara tıkla ve tuş bas (iki kutu = 1. tuş basılı tutulup 2. tuşa basılır, ör. ⌘ + V).\n" +
            "3) Fare, video kaydırma (TikTok / Reels) veya uygulama için açılır menüden seçim yap.\n" +
            "4) Profil tuşu: seçtiğin tuşa basılı tutunca (gecikme çubuğu 0 ise basar basmaz) Profil 2'ye geçilir ve orada kalınır, tekrar basılı tutunca Profil 1'e dönülür.\n" +
            "5) Bitince “Atamayı bitir”e bas. Bundan sonra yalnızca atanmış tuşlar çalışır.")
        hint.widthAnchor.constraint(equalToConstant: 720).isActive = true

        popup.addItem(withTitle: "Tüm cihazlar (Apple hariç)")
        popup.target = self; popup.action = #selector(deviceChanged)
        let devRow = NSStackView(views: [NSTextField(labelWithString: "Dinlenen cihaz:"), popup])
        devRow.spacing = 8

        func speedRow(_ title: String, _ lo: Double, _ hi: Double, _ v: Double, _ act: Selector, _ lbl: NSTextField) -> NSStackView {
            let sl = NSSlider(value: v, minValue: lo, maxValue: hi, target: self, action: act)
            sl.widthAnchor.constraint(equalToConstant: 240).isActive = true
            lbl.stringValue = String(Int(v))
            let t = NSTextField(labelWithString: title)
            t.widthAnchor.constraint(equalToConstant: 130).isActive = true
            let r = NSStackView(views: [t, sl, lbl]); r.spacing = 8
            return r
        }
        let moveRow = speedRow("İmleç hızı:", 1, 40, moveSpeed, #selector(moveSpeedChanged(_:)), moveLbl)
        let scrollRow = speedRow("Tekerlek hızı:", 1, 80, scrollSpeed, #selector(scrollSpeedChanged(_:)), scrollLbl)
        let swipeRow = speedRow("Video kaydırma:", 100, 1500, swipeAmount, #selector(swipeAmountChanged(_:)), swipeLbl)

        layerBtn.target = self; layerBtn.action = #selector(pickLayerTapped)
        layerClear.target = self; layerClear.action = #selector(clearLayer)
        layerBtn.bezelStyle = .rounded; layerClear.bezelStyle = .rounded
        layerBtn.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let holdRow = speedRow("Geçiş gecikmesi:", 0.0, 2.0, holdTime, #selector(holdTimeChanged(_:)), holdLbl)
        holdLbl.stringValue = holdTime <= 0.05 ? "anında" : String(format: "%.1f sn", holdTime)
        let layerRow = NSStackView(views: [NSTextField(labelWithString: "Profil tuşu:"), layerBtn, layerClear])
        layerRow.spacing = 8
        seg.target = self; seg.action = #selector(segChanged)
        seg.selectedSegment = 0
        updateLayerUI()

        assignBtn.target = self; assignBtn.action = #selector(toggleAssign)
        assignBtn.bezelStyle = .rounded; assignBtn.controlSize = .large
        let root = NSStackView(views: [perm, assignBtn, devRow, moveRow, scrollRow, swipeRow, layerRow, holdRow, hint, last, profLbl, seg, list])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 8

        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 800),
                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Mac Kumanda"
        win.isReleasedWhenClosed = false
        win.contentView = root
        win.center()

        // Kayıtlı atamaları yükle
        if let d = UserDefaults.standard.data(forKey: "maps2"),
           let saved = try? JSONDecoder().decode([Mapping].self, from: d) {
            for m in saved { addRow(Row(device: m.device, page: m.page, usage: m.usage,
                                        k1: m.mouse == nil ? m.k1 : nil, k2: m.k2,
                                        mouse: m.mouse, appPath: m.app, layer: m.layer ?? 0)) }
        }
        rebuildTable()

        // Klavyeden tuş yakalama (kutular için)
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { ev in
            guard let box = activeBox else { return ev }
            let code = Int(ev.keyCode)
            if ev.type == .flagsChanged {
                guard let f = modNSFlag[code], ev.modifierFlags.contains(f) else { return nil }
            }
            activeBox = nil
            box.set(code)
            return nil
        }

        onHID = { [weak self] dev, page, usage, down in self?.handle(dev, page, usage, down) }
        onDevice = { [weak self] name in self?.addDevice(name) }
        applyFilter()
        setupStatusItem()

        hidErr = startHID()
        refreshPerm()
        // İkon modu: kayıtlı atama varsa pencere gizli başlar; ilk kurulumda ayar için açılır
        if rows.isEmpty { showWindow() }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshPerm() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }

    @objc func moveSpeedChanged(_ s: NSSlider) {
        moveSpeed = s.doubleValue; moveLbl.stringValue = String(Int(s.doubleValue))
        UserDefaults.standard.set(moveSpeed, forKey: "moveSpeed")
    }
    @objc func scrollSpeedChanged(_ s: NSSlider) {
        scrollSpeed = s.doubleValue; scrollLbl.stringValue = String(Int(s.doubleValue))
        UserDefaults.standard.set(scrollSpeed, forKey: "scrollSpeed")
    }
    @objc func swipeAmountChanged(_ s: NSSlider) {
        swipeAmount = s.doubleValue; swipeLbl.stringValue = String(Int(s.doubleValue))
        UserDefaults.standard.set(swipeAmount, forKey: "swipeAmount")
    }
    @objc func actionChanged(_ b: NSPopUpButton) {
        guard let id = b.identifier?.rawValue, let row = rows.first(where: { $0.key == id }) else { return }
        let m = mouseOptions[b.indexOfSelectedItem].0
        row.mouse = m.isEmpty ? nil : m
        if m == "app" && row.appPath == nil {
            if !chooseApp(for: row) { row.mouse = nil; b.selectItem(at: 0) }
        }
        row.updateVisibility()
        commit()
    }

    @discardableResult
    func chooseApp(for row: Row) -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Açılacak uygulamayı seç"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [UTType.application]
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        row.appPath = url.path
        return true
    }

    @objc func appBtnTapped(_ b: NSButton) {
        guard let id = b.identifier?.rawValue, let row = rows.first(where: { $0.key == id }) else { return }
        if chooseApp(for: row) { commit() }
    }

    func updateStatusTitle() {
        statusItem?.button?.title = (assigning ? " ●" : "") + (layerActive ? " ②" : "")
    }

    func updateProfileUI() {
        profLbl.stringValue = layerActive ? "Aktif profil: Profil 2" : "Aktif profil: Profil 1"
        updateStatusTitle()
    }

    func setProfile(_ n: Int) {
        layerActive = (n == 1)
        updateProfileUI()
        NSSound(named: "Pop")?.play()
    }

    @objc func switchProfile() { setProfile(layerActive ? 0 : 1) }

    @objc func holdTimeChanged(_ sl: NSSlider) {
        holdTime = (sl.doubleValue * 10).rounded() / 10
        holdLbl.stringValue = holdTime <= 0.05 ? "anında" : String(format: "%.1f sn", holdTime)
        UserDefaults.standard.set(holdTime, forKey: "holdTime")
    }

    func updateLayerUI() {
        if pickingLayer { layerBtn.title = "Kumandada bir tuşa bas…"; return }
        if let k = layerKey {
            let parts = k.split(separator: "|").map(String.init)
            if parts.count >= 3, let pg = Int(parts[1]), let us = Int(parts[2]) {
                layerBtn.title = "\(parts[0]) · \(sourceName(pg, us))"
                return
            }
        }
        layerBtn.title = "Seç… (kumandada bir tuşa bas)"
    }

    @objc func pickLayerTapped() { pickingLayer = true; updateLayerUI() }

    @objc func clearLayer() {
        layerKey = nil; layerActive = false; pickingLayer = false; updateProfileUI()
        UserDefaults.standard.removeObject(forKey: "layerKey")
        updateLayerUI()
    }

    @objc func segChanged() { editLayer = seg.selectedSegment; applyFilter() }

    func refreshPerm() {
        let ax = AXIsProcessTrusted(), im = CGPreflightListenEventAccess()
        perm.stringValue = "Erişilebilirlik: \(ax ? "VAR ✅" : "YOK ❌")   Giriş İzleme: \(im ? "VAR ✅" : "YOK ❌")"
            + (hidErr == kIOReturnSuccess ? "" : "   ⚠️ HID açılamadı (\(hidErr))")
        perm.isHidden = ax && im && hidErr == kIOReturnSuccess   // her şey tamamsa satırı gizle
    }

    @objc func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    @objc func toggleAssign() {
        assigning.toggle()
        Hold.stop(); layerActive = false; pickingLayer = false; updateLayerUI(); updateProfileUI()
        activeBox?.refresh(); activeBox = nil
        if !assigning { clearEmpty(); commit() }
        updateModeUI()
    }

    func updateModeUI() {
        assignBtn.title = assigning ? "⏹ Atamayı bitir" : "▶︎ Atamayı başlat"
        updateStatusTitle()
        last.stringValue = assigning ? "Atama açık: kumandada bir tuşa bas."
                                     : "Atama kapalı. Yalnızca atanmış tuşlar çalışır."
    }

    func menuIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke(); NSColor.black.setFill()
            let body = NSBezierPath(roundedRect: NSRect(x: 5.5, y: 1.5, width: 7, height: 15), xRadius: 3.2, yRadius: 3.2)
            body.lineWidth = 1.3; body.stroke()
            NSBezierPath(ovalIn: NSRect(x: 7.4, y: 10.6, width: 3.2, height: 3.2)).fill()
            NSBezierPath(ovalIn: NSRect(x: 8.0, y: 6.6, width: 2.0, height: 2.0)).fill()
            NSBezierPath(ovalIn: NSRect(x: 8.0, y: 3.6, width: 2.0, height: 2.0)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = menuIcon()
        statusItem.button?.toolTip = "Mac Kumanda"
        let menu = NSMenu()
        let show = NSMenuItem(title: "Pencereyi aç", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        let quit = NSMenuItem(title: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let prof = NSMenuItem(title: "Profili değiştir", action: #selector(switchProfile), keyEquivalent: "")
        prof.target = self
        menu.addItem(prof); menu.addItem(show); menu.addItem(.separator()); menu.addItem(quit)
        statusItem.menu = menu
    }

    func execute(_ m: Mapping, _ base: String, _ down: Bool) {
        if let mo = m.mouse {
            switch mo {
            case "app": if down, let path = m.app { openApp(path) }
            case "left", "right", "middle", "double": if down { mouseClick(mo) }
            case "videoNext": if down { videoSwipe(next: true) }
            case "videoPrev": if down { videoSwipe(next: false) }
            default: if down { Hold.press(base, mo) } else { Hold.release(base) }
            }
            return
        }
        if down { performMapping(m) }
    }

    func handle(_ dev: String, _ page: Int, _ usage: Int, _ down: Bool) {
        if let s = selected, dev != s { return }
        let base = "\(dev)|\(page)|\(usage)"

        // Profil tuşunu seçme
        if pickingLayer {
            guard down else { return }
            layerKey = base; pickingLayer = false
            UserDefaults.standard.set(base, forKey: "layerKey")
            updateLayerUI()
            return
        }

        // Atama modu: yeni tuşlar için satır oluştur, atamaları çalıştırma
        if assigning {
            guard down else { return }
            let key = base + "|\(editLayer)"
            last.stringValue = "Son sinyal: \(dev) · \(sourceName(page, usage))"
            if let row = rows.first(where: { $0.key == key }) { row.flash() }
            else { addRow(Row(device: dev, page: page, usage: usage, k1: nil, k2: nil, layer: editLayer)) }
            return
        }

        // Profil tuşu: uzun basınca profil değişir ve kalır; kısa basış kendi atamasını çalıştırır
        if base == layerKey {
            if down {
                if layerDown { return } // tekrar eden sinyalleri yok say
                layerDown = true; layerFired = false
                layerTimer?.invalidate()
                if holdTime <= 0.05 {   // gecikme 0: tuşa basar basmaz geç
                    layerFired = true
                    setProfile(layerActive ? 0 : 1)
                    return
                }
                let t = Timer(timeInterval: holdTime, repeats: false) { [weak self] _ in
                    guard let self = self, self.layerDown else { return }
                    self.layerFired = true
                    self.setProfile(self.layerActive ? 0 : 1)
                }
                RunLoop.main.add(t, forMode: .common)
                layerTimer = t
            } else {
                layerTimer?.invalidate(); layerTimer = nil
                let wasDown = layerDown
                layerDown = false
                if wasDown && !layerFired, let m = table[base + "|\(layerActive ? 1 : 0)"] {
                    execute(m, base, true); execute(m, base, false)
                }
            }
            return
        }

        if !down { Hold.release(base); return }
        guard let m = table[base + "|\(layerActive ? 1 : 0)"] else { return }
        execute(m, base, true)
    }

    func addRow(_ row: Row) {
        row.b1.onChange = { [weak self] _ in self?.commit() }
        row.b2.onChange = { [weak self] _ in self?.commit() }
        row.act.target = self; row.act.action = #selector(actionChanged(_:))
        row.act.identifier = NSUserInterfaceItemIdentifier(row.key)
        row.appBtn.target = self; row.appBtn.action = #selector(appBtnTapped(_:))
        row.appBtn.identifier = NSUserInterfaceItemIdentifier(row.key)
        row.del.target = self; row.del.action = #selector(deleteTapped(_:))
        row.del.identifier = NSUserInterfaceItemIdentifier(row.key)
        rows.append(row)
        list.addArrangedSubview(row.view)
        applyFilter()
    }

    @objc func deleteTapped(_ b: NSButton) {
        guard let id = b.identifier?.rawValue, let i = rows.firstIndex(where: { $0.key == id }) else { return }
        let r = rows.remove(at: i)
        list.removeArrangedSubview(r.view); r.view.removeFromSuperview()
        commit()
    }

    func rebuildTable() {
        table = [:]
        for r in rows {
            if let mo = r.mouse {
                if mo == "app" && r.appPath == nil { continue }
                table[r.key] = Mapping(device: r.device, page: r.page, usage: r.usage, k1: -1, k2: nil,
                                       mouse: mo, app: r.appPath, layer: r.layer)
                continue
            }
            let k1 = r.b1.code ?? r.b2.code
            let k2 = r.b1.code == nil ? nil : r.b2.code
            if let k1 = k1 {
                table[r.key] = Mapping(device: r.device, page: r.page, usage: r.usage, k1: k1, k2: k2, layer: r.layer)
            }
        }
    }

    func commit() {
        rebuildTable()
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(table.values)), forKey: "maps2")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // Dock'ta görünmez, yalnızca menü çubuğu ikonu
app.run()
