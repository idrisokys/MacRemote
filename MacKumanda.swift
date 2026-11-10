import Cocoa
import IOKit.hid
import UniformTypeIdentifiers

// ---------- Veri ----------
struct Mapping: Codable { var device: String; var page: Int; var usage: Int; var k1: Int; var k2: Int?; var mouse: String?; var app: String?; var layer: Int?; var gesture: [[Double]]? }


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
    ("videoNext", "📱 Aşağı kaydır"), ("videoPrev", "📱 Yukarı kaydır"),
    ("swipeRight", "📱 Sağa kaydır"), ("swipeLeft", "📱 Sola kaydır"),
    ("gesture", "✍️ Hareket çiz"),
    ("moveUp", "🖱 İmleç yukarı"), ("moveDown", "🖱 İmleç aşağı"),
    ("moveLeft", "🖱 İmleç sola"), ("moveRight", "🖱 İmleç sağa"),
    ("app", "🚀 Uygulama aç")
]
var moveSpeed: Double = UserDefaults.standard.object(forKey: "moveSpeed") as? Double ?? 12
var scrollSpeed: Double = UserDefaults.standard.object(forKey: "scrollSpeed") as? Double ?? 20
var swipeAmount: Double = UserDefaults.standard.object(forKey: "swipeAmountV2") as? Double ?? 120      // yukarı/aşağı
var swipeAmountH: Double = UserDefaults.standard.object(forKey: "swipeAmountHV2") as? Double ?? 120     // sağa/sola

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

var lastSwipe = Date.distantPast

func mouseScrollH(_ amount: Int32) {
    guard let e = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .pixel,
                          wheelCount: 2, wheel1: 0, wheel2: amount, wheel3: 0) else { return }
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(amount))
    e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(amount))
    e.post(tap: .cghidEventTap)
}

// ---------- Çizilen hareket (touchpad alanı) ----------
// Kayıt: [dx, dy, t] — ilk noktaya göre ekran yönünde (y aşağı), t saniye
func playGesture(_ g: [[Double]]) {
    guard g.count >= 2, g.allSatisfy({ $0.count == 3 }) else { return }
    let now = Date()
    if now.timeIntervalSince(lastSwipe) < 0.5 { return }
    lastSwipe = now
    let p0 = cursorPos()
    let total = max(g[g.count - 1][2], 0.001)
    let k = min(1.0, 0.45 / total)           // çok yavaş çizilen hareketi hızlandır (fiske gibi çalışsın)
    let src = CGEventSource(stateID: .hidSystemState)
    let post: (CGEventType, CGPoint) -> Void = { type, pt in
        if let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pt, mouseButton: .left) {
            e.post(tap: .cghidEventTap)
        }
    }
    post(.leftMouseDown, p0)
    var endPt = p0
    for i in 1..<g.count {
        let q = g[i]
        let pt = clampToDisplays(CGPoint(x: p0.x + q[0], y: p0.y + q[1]))
        endPt = pt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 + q[2] * k + Double(i) * 0.0005) { post(.leftMouseDragged, pt) }
    }
    let end = 0.02 + total * k + Double(g.count) * 0.0005
    DispatchQueue.main.asyncAfter(deadline: .now() + end + 0.02) { post(.leftMouseUp, endPt) }
    DispatchQueue.main.asyncAfter(deadline: .now() + end + 0.06) { CGWarpMouseCursorPosition(p0) } // imleç yerine dönsün
}

final class GesturePad: NSView {
    var points: [[Double]] = []
    var viewPath: [NSPoint] = []
    var times: [Double] = []
    var t0 = Date()
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func load(_ g: [[Double]]) {
        points = g
        let xs = g.map { $0[0] }, ys = g.map { -$0[1] }
        let cx = ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2, cy = ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2
        viewPath = zip(xs, ys).map { NSPoint(x: Double(bounds.midX) + $0 - cx, y: Double(bounds.midY) + $1 - cy) }
        needsDisplay = true
    }
    override func mouseDown(with ev: NSEvent) {
        viewPath = [convert(ev.locationInWindow, from: nil)]
        times = [0]; t0 = Date(); points = []
        needsDisplay = true
    }
    override func mouseDragged(with ev: NSEvent) {
        let p = convert(ev.locationInWindow, from: nil)
        viewPath.append(NSPoint(x: min(max(p.x, 0), bounds.maxX), y: min(max(p.y, 0), bounds.maxY)))
        times.append(Date().timeIntervalSince(t0))
        needsDisplay = true
    }
    override func mouseUp(with ev: NSEvent) {
        var len = 0.0
        for i in 1..<max(1, viewPath.count) { len += Double(hypot(viewPath[i].x - viewPath[i-1].x, viewPath[i].y - viewPath[i-1].y)) }
        guard viewPath.count >= 2, len >= 8 else { viewPath = []; points = []; needsDisplay = true; return }
        var idx = Array(0..<viewPath.count)
        if idx.count > 60 {
            let step = Double(idx.count - 1) / 59.0
            idx = (0..<60).map { Int((Double($0) * step).rounded()) }
        }
        let o = viewPath[0]
        points = idx.map { [Double(viewPath[$0].x - o.x), -Double(viewPath[$0].y - o.y), times[$0]] }
        viewPath = idx.map { viewPath[$0] }
        needsDisplay = true
    }
    override func draw(_ r: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 18, yRadius: 18)
        NSColor.controlBackgroundColor.setFill(); bg.fill()
        NSColor.tertiaryLabelColor.setStroke(); bg.lineWidth = 2; bg.stroke()
        if viewPath.count < 2 {
            let t = "Fareyi basılı tutup sürükleyerek hareketi çiz" as NSString
            let at: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor]
            let sz = t.size(withAttributes: at)
            t.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2), withAttributes: at)
            return
        }
        let path = NSBezierPath()
        path.move(to: viewPath[0]); for p in viewPath.dropFirst() { path.line(to: p) }
        path.lineWidth = 5; path.lineCapStyle = .round; path.lineJoinStyle = .round
        NSColor.controlAccentColor.setStroke(); path.stroke()
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: NSRect(x: viewPath[0].x - 7, y: viewPath[0].y - 7, width: 14, height: 14)).fill()
        NSColor.systemRed.setFill()
        let e = viewPath[viewPath.count - 1]
        NSBezierPath(ovalIn: NSRect(x: e.x - 7, y: e.y - 7, width: 14, height: 14)).fill()
    }
}

// TikTok / Instagram Reels gibi videoları tek vuruşta kaydırır (bir basış = bir video)
enum SwipeDir { case down, up, right, left }
func swipe(_ dir: SwipeDir) {
    let now = Date()
    if now.timeIntervalSince(lastSwipe) < 0.45 { return } // animasyon bitmeden ikinci kaydırmayı yok say
    lastSwipe = now
    let vertical = (dir == .down || dir == .up)
    let total = max(1, Int((vertical ? swipeAmount : swipeAmountH).rounded()))
    let steps = min(8, total)                      // 1 piksel gibi çok küçük değerler de uygulanabilsin
    let base = total / steps, extra = total % steps
    // aşağı/sağa kaydır: içerik ilerler (negatif), yukarı/sola kaydır: geri döner (pozitif)
    let sign: Int32 = (dir == .down || dir == .right) ? -1 : 1
    for i in 0..<steps {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012 * Double(i)) {
            let amt = sign * Int32(base + (i < extra ? 1 : 0))
            if vertical { mouseScroll(amt) } else { mouseScrollH(amt) }
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
    var gesture: [[Double]]? { didSet { refreshGestureTitle() } }
    var appPath: String? { didSet { refreshAppTitle() } }
    let label: NSTextField
    let act = NSPopUpButton(frame: .zero, pullsDown: false)
    let appBtn = NSButton(title: "Uygulama seç…", target: nil, action: nil)
    let gestureBtn = NSButton(title: "✍️ Hareket çiz…", target: nil, action: nil)
    let b1 = KeyBox(frame: .zero), b2 = KeyBox(frame: .zero)
    let plus = NSTextField(labelWithString: "+")
    let del = NSButton(title: "Sil", target: nil, action: nil)
    let view: NSStackView
    var key: String { "\(device)|\(page)|\(usage)|\(layer)" }
    var isEmpty: Bool { b1.code == nil && b2.code == nil && mouse == nil }

    init(device: String, page: Int, usage: Int, k1: Int?, k2: Int?, mouse: String? = nil, appPath: String? = nil, layer: Int = 0, gesture: [[Double]]? = nil) {
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
        gestureBtn.bezelStyle = .rounded
        gestureBtn.widthAnchor.constraint(equalToConstant: 270).isActive = true
        view = NSStackView(views: [label, act, appBtn, gestureBtn, b1, plus, b2, del])
        view.spacing = 8
        self.appPath = appPath
        self.gesture = gesture
        refreshAppTitle(); refreshGestureTitle()
        updateVisibility()
    }
    func refreshGestureTitle() {
        gestureBtn.title = gesture.map { "✍️ Hareket kayıtlı (\($0.count) nokta) – değiştir" } ?? "✍️ Hareket çiz…"
    }
    func refreshAppTitle() { appBtn.title = appPath.map { "🚀 " + appName($0) } ?? "Uygulama seç…" }
    func updateVisibility() {
        let kb = (mouse == nil)
        b1.isHidden = !kb; plus.isHidden = !kb; b2.isHidden = !kb
        appBtn.isHidden = (mouse != "app")
        gestureBtn.isHidden = (mouse != "gesture")
        refreshGestureTitle()
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
    var profile = 0                      // 0, 1, 2 -> Profil 1, 2, 3
    let profileCount = 3
    var pickingLayer = false
    var lastProfileSwitch = Date.distantPast
    let profLbl = NSTextField(labelWithString: "Aktif profil: Profil 1")
    let layerBtn = NSButton(title: "Seç…", target: nil, action: nil)
    let layerClear = NSButton(title: "Kaldır", target: nil, action: nil)
    let seg = NSSegmentedControl(labels: ["Profil 1", "Profil 2", "Profil 3"],
                                 trackingMode: .selectOne, target: nil, action: nil)
    var hidErr: IOReturn = 0
    let moveLbl = NSTextField(labelWithString: "")
    let scrollLbl = NSTextField(labelWithString: "")
    let swipeSlider = NSSlider(value: 120, minValue: 1, maxValue: 3000, target: nil, action: nil)
    let swipeSliderH = NSSlider(value: 120, minValue: 1, maxValue: 3000, target: nil, action: nil)
    let swipeField = NSTextField(string: "")
    let swipeFieldH = NSTextField(string: "")
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
            "3) Fare, kaydırma, kendi çizdiğin hareket (✍️ Hareket çiz) veya uygulama için açılır menüden seçim yap.\n" +
            "4) Profil tuşu: seçtiğin tuşa her basışta sıradaki profile geçilir (1 → 2 → 3 → 1).\n" +
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
            t.widthAnchor.constraint(equalToConstant: 160).isActive = true
            let r = NSStackView(views: [t, sl, lbl]); r.spacing = 8
            return r
        }
        let moveRow = speedRow("İmleç hızı:", 1, 40, moveSpeed, #selector(moveSpeedChanged(_:)), moveLbl)
        let scrollRow = speedRow("Tekerlek hızı:", 1, 80, scrollSpeed, #selector(scrollSpeedChanged(_:)), scrollLbl)
        func amountRow(_ title: String, _ sl: NSSlider, _ f: NSTextField, _ v: Double, _ a: Selector, _ fa: Selector) -> NSStackView {
            sl.target = self; sl.action = a; sl.doubleValue = v
            sl.widthAnchor.constraint(equalToConstant: 240).isActive = true
            f.stringValue = String(Int(v)); f.target = self; f.action = fa
            f.widthAnchor.constraint(equalToConstant: 70).isActive = true
            let t = NSTextField(labelWithString: title)
            t.widthAnchor.constraint(equalToConstant: 160).isActive = true
            let hint = NSTextField(labelWithString: "(sayı kutusuna 1–20000 yazabilirsin)")
            hint.textColor = .secondaryLabelColor
            let r = NSStackView(views: [t, sl, f, hint]); r.spacing = 8
            return r
        }
        let swipeRow = amountRow("Yukarı/aşağı kaydırma:", swipeSlider, swipeField, swipeAmount, #selector(swipeAmountChanged(_:)), #selector(swipeFieldChanged(_:)))
        let swipeRowH = amountRow("Sağa/sola kaydırma:", swipeSliderH, swipeFieldH, swipeAmountH, #selector(swipeAmountHChanged(_:)), #selector(swipeFieldHChanged(_:)))

        layerBtn.target = self; layerBtn.action = #selector(pickLayerTapped)
        layerClear.target = self; layerClear.action = #selector(clearLayer)
        layerBtn.bezelStyle = .rounded; layerClear.bezelStyle = .rounded
        layerBtn.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let layerRow = NSStackView(views: [NSTextField(labelWithString: "Profil tuşu:"), layerBtn, layerClear])
        layerRow.spacing = 8
        seg.target = self; seg.action = #selector(segChanged)
        seg.selectedSegment = 0
        updateLayerUI()

        assignBtn.target = self; assignBtn.action = #selector(toggleAssign)
        assignBtn.bezelStyle = .rounded; assignBtn.controlSize = .large
        let root = NSStackView(views: [perm, assignBtn, devRow, moveRow, scrollRow, swipeRow, swipeRowH, layerRow, hint, last, profLbl, seg, list])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 8

        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 830),
                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Mac Kumanda"
        win.isReleasedWhenClosed = false
        win.contentView = root
        win.center()

        // Kayıtlı atamaları yükle
        if let d = UserDefaults.standard.data(forKey: "maps2"),
           let saved = try? JSONDecoder().decode([Mapping].self, from: d) {
            for m in saved where m.mouse != "macro" { addRow(Row(device: m.device, page: m.page, usage: m.usage,
                                        k1: m.mouse == nil ? m.k1 : nil, k2: m.k2,
                                        mouse: m.mouse, appPath: m.app, layer: m.layer ?? 0, gesture: m.gesture)) }
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
    @objc func swipeAmountHChanged(_ sl: NSSlider) {
        swipeAmountH = sl.doubleValue.rounded(); swipeFieldH.stringValue = String(Int(swipeAmountH))
        UserDefaults.standard.set(swipeAmountH, forKey: "swipeAmountHV2")
    }
    @objc func swipeAmountChanged(_ sl: NSSlider) {
        swipeAmount = sl.doubleValue.rounded(); swipeField.stringValue = String(Int(swipeAmount))
        UserDefaults.standard.set(swipeAmount, forKey: "swipeAmountV2")
    }
    @objc func swipeFieldChanged(_ f: NSTextField) {
        let v = Double(min(max(f.integerValue, 1), 20000))
        swipeAmount = v; f.stringValue = String(Int(v)); swipeSlider.doubleValue = v
        UserDefaults.standard.set(v, forKey: "swipeAmountV2")
    }
    @objc func swipeFieldHChanged(_ f: NSTextField) {
        let v = Double(min(max(f.integerValue, 1), 20000))
        swipeAmountH = v; f.stringValue = String(Int(v)); swipeSliderH.doubleValue = v
        UserDefaults.standard.set(v, forKey: "swipeAmountHV2")
    }
    @objc func actionChanged(_ b: NSPopUpButton) {
        guard let id = b.identifier?.rawValue, let row = rows.first(where: { $0.key == id }) else { return }
        let m = mouseOptions[b.indexOfSelectedItem].0
        row.mouse = m.isEmpty ? nil : m
        if m == "app" && row.appPath == nil {
            if !chooseApp(for: row) { row.mouse = nil; b.selectItem(at: 0) }
        }
        if m == "gesture", let c = row.gesture?.first?.count, c != 3 { row.gesture = nil }
        if m == "gesture" && row.gesture == nil {
            if !drawGesture(for: row) { row.mouse = nil; b.selectItem(at: 0) }
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

    @discardableResult
    func drawGesture(for row: Row) -> Bool {
        let pad = GesturePad(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        if let g = row.gesture { pad.load(g) }
        let a = NSAlert()
        a.messageText = "Hareketi çiz"
        a.informativeText = "Kutuda fareyi basılı tutup sürükleyerek hareketi çiz (ör. aşağıdan yukarı doğru çizgi). " +
            "Yeşil nokta başlangıç, kırmızı nokta bitiş. Tekrar çizersen öncekinin yerine geçer.\n" +
            "Tuşa basınca hareket, o anda imlecin bulunduğu yerden başlayıp yeniden oynatılır."
        a.accessoryView = pad
        a.addButton(withTitle: "Kaydet"); a.addButton(withTitle: "İptal")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn, !pad.points.isEmpty else { return false }
        row.gesture = pad.points
        return true
    }

    @objc func gestureBtnTapped(_ b: NSButton) {
        guard let id = b.identifier?.rawValue, let row = rows.first(where: { $0.key == id }) else { return }
        if drawGesture(for: row) { commit() }
    }

    @objc func appBtnTapped(_ b: NSButton) {
        guard let id = b.identifier?.rawValue, let row = rows.first(where: { $0.key == id }) else { return }
        if chooseApp(for: row) { commit() }
    }

    func updateStatusTitle() {
        guard let b = statusItem?.button else { return }
        // Profil numarası menü çubuğuna sığabilecek en büyük puntoyla yazılır
        let size = NSStatusBar.system.thickness - 2
        let t = (assigning ? " ●" : "") + " \(profile + 1)"
        b.imagePosition = .imageLeft
        b.attributedTitle = NSAttributedString(string: t, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .heavy)])
    }

    func updateProfileUI() {
        profLbl.stringValue = "Aktif profil: Profil \(profile + 1)"
        updateStatusTitle()
    }

    func setProfile(_ n: Int) {
        profile = n % profileCount
        updateProfileUI()
        NSSound(named: "Pop")?.play()
    }

    @objc func switchProfile() { setProfile(profile + 1) }

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
        layerKey = nil; profile = 0; pickingLayer = false; updateProfileUI()
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
        Hold.stop(); profile = 0; pickingLayer = false; updateLayerUI(); updateProfileUI()
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
        updateStatusTitle()
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
            case "videoNext": if down { swipe(.down) }
            case "videoPrev": if down { swipe(.up) }
            case "swipeRight": if down { swipe(.right) }
            case "swipeLeft": if down { swipe(.left) }
            case "gesture": if down, let g = m.gesture { playGesture(g) }
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

        // Profil tuşu: her basışta sıradaki profile geçer (Profil 1 → 2 → 3 → 1)
        if base == layerKey {
            guard down else { return }
            let now = Date()
            if now.timeIntervalSince(lastProfileSwitch) < 0.25 { return } // tekrar eden sinyalleri yok say
            lastProfileSwitch = now
            setProfile(profile + 1)
            return
        }

        if !down { Hold.release(base); return }
        guard let m = table[base + "|\(profile)"] else { return }
        execute(m, base, true)
    }

    func addRow(_ row: Row) {
        row.b1.onChange = { [weak self] _ in self?.commit() }
        row.b2.onChange = { [weak self] _ in self?.commit() }
        row.act.target = self; row.act.action = #selector(actionChanged(_:))
        row.act.identifier = NSUserInterfaceItemIdentifier(row.key)
        row.appBtn.target = self; row.appBtn.action = #selector(appBtnTapped(_:))
        row.appBtn.identifier = NSUserInterfaceItemIdentifier(row.key)
        row.gestureBtn.target = self; row.gestureBtn.action = #selector(gestureBtnTapped(_:))
        row.gestureBtn.identifier = NSUserInterfaceItemIdentifier(row.key)
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
                if mo == "gesture" && r.gesture == nil { continue }
                table[r.key] = Mapping(device: r.device, page: r.page, usage: r.usage, k1: -1, k2: nil,
                                       mouse: mo, app: r.appPath, layer: r.layer, gesture: r.gesture)
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
