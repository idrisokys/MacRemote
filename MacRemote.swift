import Cocoa
import IOKit.hid
import UniformTypeIdentifiers

// ---------- Veri ----------
struct Mapping: Codable { var device: String; var page: Int; var usage: Int; var k1: Int; var k2: Int?; var mouse: String?; var app: String?; var layer: Int?; var gesture: [[Double]]? }

enum Layout {
    static let w: CGFloat = 320          // pencere 350 px, kenarlarda 15 px boşluk

    static func text(_ s: String, size: CGFloat = 11, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: size); t.textColor = color
        t.widthAnchor.constraint(equalToConstant: w).isActive = true
        return t
    }
    static func row(_ v: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: v); s.spacing = spacing; s.distribution = .fill
        s.widthAnchor.constraint(equalToConstant: w).isActive = true
        return s
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

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

// ---------- Ayarlar (çubuk + sayı kutusu) ----------
final class Setting: NSObject {
    let key: String, title: String, lo: Double, hi: Double
    private(set) var value: Double

    init(_ key: String, _ title: String, _ lo: Double, _ hi: Double, _ def: Double) {
        self.key = key; self.title = title; self.lo = lo; self.hi = hi
        let v = UserDefaults.standard.object(forKey: key) as? Double ?? def
        value = min(max(v.rounded(), lo), hi)
        super.init()
    }
    // Arayüz elemanları yalnızca pencere kurulurken (tembel) oluşturulur
    lazy var slider: NSSlider = {
        let s = NSSlider(value: value, minValue: lo, maxValue: hi, target: self, action: #selector(sliderMoved))
        s.widthAnchor.constraint(equalToConstant: Layout.w).isActive = true
        return s
    }()
    lazy var field: NSTextField = {
        let f = NSTextField(string: String(Int(value)))
        f.alignment = .right; f.target = self; f.action = #selector(fieldEdited)
        f.widthAnchor.constraint(equalToConstant: 60).isActive = true
        return f
    }()
    lazy var view: NSStackView = {
        let t = NSTextField(labelWithString: title)
        t.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let s = NSStackView(views: [Layout.row([t, field]), slider])
        s.orientation = .vertical; s.alignment = .leading; s.spacing = 4
        return s
    }()

    private func apply(_ v: Double) {
        value = min(max(v.rounded(), lo), hi)
        slider.doubleValue = value; field.stringValue = String(Int(value))
        UserDefaults.standard.set(value, forKey: key)
    }
    @objc private func sliderMoved() { apply(slider.doubleValue) }
    @objc private func fieldEdited() { apply(Double(field.integerValue)) }
}

let moveSpeed   = Setting("moveSpeed", "İmleç hızı", 1, 40, 12)
let scrollSpeed = Setting("scrollSpeed", "Tekerlek hızı", 1, 80, 20)
let swipeV      = Setting("swipeAmountV2", "Yukarı/aşağı kaydırma", 1, 1000, 120)
let swipeH      = Setting("swipeAmountHV2", "Sağa/sola kaydırma", 1, 1000, 120)

// ---------- Tuş gönderme ----------
let hidSource = CGEventSource(stateID: .hidSystemState)   // tek kez oluşturulur, her olayda yeniden kurulmaz

// Ok/gezinme/F tuşları gerçek klavyede fn bayrağıyla gelir (Mission Control gibi kısayollar bunu bekler)
let fnKeys: Set<Int> = [123, 124, 125, 126, 115, 116, 117, 119, 121,
                        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

func postKey(_ code: Int, down: Bool, flags: CGEventFlags) {
    if modFlag[code] != nil {
        // Değiştirici tuşlar (⌘ ⇧ ⌥ ⌃ fn) gerçek klavyede "flagsChanged" olayıdır
        if let e = CGEvent(source: hidSource) {
            e.type = .flagsChanged
            e.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
        return
    }
    guard let e = CGEvent(keyboardEventSource: hidSource, virtualKey: CGKeyCode(code), keyDown: down) else { return }
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

func cursorPos() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

// Ekran sınırları önbelleğe alınır; imleç her hareketinde (60 Hz) ekran listesi sorgulanmaz
var displayBounds = CGRect.null
func refreshDisplays() {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    displayBounds = ids.prefix(Int(n)).reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
}

func clampToDisplays(_ p: CGPoint) -> CGPoint {
    let all = displayBounds
    if all.isNull { return p }
    return CGPoint(x: min(max(p.x, all.minX), all.maxX - 1), y: min(max(p.y, all.minY), all.maxY - 1))
}

func moveCursor(dx: Double, dy: Double) {
    let old = cursorPos()
    let np = clampToDisplays(CGPoint(x: old.x + dx, y: old.y + dy))
    guard let e = CGEvent(mouseEventSource: hidSource, mouseType: .mouseMoved, mouseCursorPosition: np, mouseButton: .left) else { return }
    e.setIntegerValueField(.mouseEventDeltaX, value: Int64(np.x - old.x))
    e.setIntegerValueField(.mouseEventDeltaY, value: Int64(np.y - old.y))
    e.post(tap: .cghidEventTap)
}

func mouseClick(_ kind: String) {
    let p = cursorPos()
    var downT = CGEventType.leftMouseDown, upT = CGEventType.leftMouseUp, btn = CGMouseButton.left
    switch kind {
    case "right": downT = .rightMouseDown; upT = .rightMouseUp; btn = .right
    case "middle": downT = .otherMouseDown; upT = .otherMouseUp; btn = .center
    default: break
    }
    let times = (kind == "double") ? 2 : 1
    for i in 1...times {
        for t in [downT, upT] {
            if let e = CGEvent(mouseEventSource: hidSource, mouseType: t, mouseCursorPosition: p, mouseButton: btn) {
                e.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                e.post(tap: .cghidEventTap)
            }
        }
    }
}

func mouseScroll(_ amount: Int32) {
    CGEvent(scrollWheelEvent2Source: hidSource, units: .pixel,
            wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
}

var lastSwipe = Date.distantPast

func mouseScrollH(_ amount: Int32) {
    guard let e = CGEvent(scrollWheelEvent2Source: hidSource, units: .pixel,
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
    let post: (CGEventType, CGPoint) -> Void = { type, pt in
        CGEvent(mouseEventSource: hidSource, mouseType: type, mouseCursorPosition: pt, mouseButton: .left)?
            .post(tap: .cghidEventTap)
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
    let total = max(1, Int((vertical ? swipeV : swipeH).value))
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
        let v = max(1, moveSpeed.value * f)
        let sc = Int32(max(1, scrollSpeed.value * f))
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

// Cihaz adı/üretici bilgisi cihaz başına bir kez okunur (her tuş olayında IOKit sorgusu yapılmaz)
struct DevInfo { let name: String; let ignored: Bool }
var devInfo: [UnsafeMutableRawPointer: DevInfo] = [:]

func info(_ dev: IOHIDDevice) -> DevInfo {
    let key = Unmanaged.passUnretained(dev).toOpaque()
    if let i = devInfo[key] { return i }
    let vendor = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? 0
    let i = DevInfo(name: IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "Bilinmeyen",
                    ignored: vendor == 0x05AC || vendor == 0x004C)   // Apple cihazları yok sayılır
    devInfo[key] = i
    return i
}

func startHID() -> IOReturn {
    let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(hid, nil)
    IOHIDManagerRegisterInputValueCallback(hid, { _, _, _, value in
        let el = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(el))
        let usage = Int(IOHIDElementGetUsage(el))
        guard page == 0x07 || page == 0x0C, usage > 0, usage < 0xFFFF else { return }
        let d = info(IOHIDElementGetDevice(el))
        if d.ignored { return }
        onHID?(d.name, page, usage, IOHIDValueGetIntegerValue(value) != 0)
    }, nil)
    IOHIDManagerRegisterDeviceMatchingCallback(hid, { _, _, _, dev in
        let d = info(dev)
        if !d.ignored { onDevice?(d.name) }
    }, nil)
    IOHIDManagerRegisterDeviceRemovalCallback(hid, { _, _, _, dev in
        devInfo[Unmanaged.passUnretained(dev).toOpaque()] = nil
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
        widthAnchor.constraint(equalToConstant: 125).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() { title = code.map { keyName($0) } ?? "boş – tıkla" }
    @objc func begin() { activeBox?.refresh(); activeBox = self; title = "Tuşa bas…" }
    func set(_ c: Int) { code = c; onChange?(c) }
}

// ---------- Satır (350 px pencereye göre dikey kart) ----------
final class Row {
    let device: String, page: Int, usage: Int
    let layer: Int
    var mouse: String?
    var gesture: [[Double]]? { didSet { refreshTitles() } }
    var appPath: String? { didSet { refreshTitles() } }
    let label: NSTextField
    let act = NSPopUpButton(frame: .zero, pullsDown: false)
    let appBtn = NSButton(title: "Uygulama seç…", target: nil, action: nil)
    let gestureBtn = NSButton(title: "✍️ Hareket çiz…", target: nil, action: nil)
    let b1 = KeyBox(frame: .zero), b2 = KeyBox(frame: .zero)
    let del = NSButton(title: "Sil", target: nil, action: nil)
    let keys: NSStackView
    let view: NSStackView
    var key: String { "\(device)|\(page)|\(usage)|\(layer)" }
    var isEmpty: Bool { b1.code == nil && b2.code == nil && mouse == nil }

    init(device: String, page: Int, usage: Int, k1: Int?, k2: Int?, mouse: String? = nil, appPath: String? = nil, layer: Int = 0, gesture: [[Double]]? = nil) {
        self.device = device; self.page = page; self.usage = usage; self.mouse = mouse; self.layer = layer
        let lbl = NSTextField(labelWithString: "\(device) · \(sourceName(page, usage))")
        lbl.lineBreakMode = .byTruncatingTail
        lbl.font = .systemFont(ofSize: 12, weight: .medium)
        lbl.toolTip = lbl.stringValue
        lbl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        lbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label = lbl
        del.bezelStyle = .rounded; del.controlSize = .small
        b1.code = k1; b2.code = k2
        for o in mouseOptions { act.addItem(withTitle: o.1) }
        if let m = mouse, let i = mouseOptions.firstIndex(where: { $0.0 == m }) { act.selectItem(at: i) }
        for b in [act, appBtn, gestureBtn] as [NSControl] { b.widthAnchor.constraint(equalToConstant: Layout.w).isActive = true }
        appBtn.bezelStyle = .rounded; gestureBtn.bezelStyle = .rounded
        let plus = NSTextField(labelWithString: "+")
        keys = NSStackView(views: [b1, plus, b2]); keys.spacing = 8
        let sep = NSBox(); sep.boxType = .separator
        sep.widthAnchor.constraint(equalToConstant: Layout.w).isActive = true
        view = NSStackView(views: [Layout.row([lbl, del]), act, keys, appBtn, gestureBtn, sep])
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 6
        self.appPath = appPath
        self.gesture = gesture
        refreshTitles()
        updateVisibility()
    }
    func refreshTitles() {
        gestureBtn.title = gesture.map { "✍️ Hareket kayıtlı (\($0.count) nokta) – değiştir" } ?? "✍️ Hareket çiz…"
        appBtn.title = appPath.map { "🚀 " + appName($0) } ?? "Uygulama seç…"
    }
    func updateVisibility() {
        keys.isHidden = (mouse != nil)
        appBtn.isHidden = (mouse != "app")
        gestureBtn.isHidden = (mouse != "gesture")
    }
    func flash() {
        label.textColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.label.textColor = .labelColor }
    }
}

// ---------- Uygulama ----------
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var win: NSWindow!
    var statusItem: NSStatusItem!
    let perm = Layout.text("", size: 11, color: .labelColor)
    let last = Layout.text("Atama kapalı. Yalnızca atanmış tuşlar çalışır.")
    let list = NSStackView()
    var rows: [Row] = []
    var table: [String: Mapping] = [:]
    var assigning = false
    var editLayer = 0
    var layerKey: String? = UserDefaults.standard.string(forKey: "layerKey")
    var profile = 0                      // 0, 1 -> Profil 1, 2
    let profileCount = 2
    var pickingLayer = false
    var lastProfileSwitch = Date.distantPast
    var lastHide = Date.distantPast
    var busy = false                     // diyalog açıkken pencere gizlenmesin
    var hidErr: IOReturn = 0
    let profLbl = NSTextField(labelWithString: "Aktif profil: Profil 1")
    let layerBtn = NSButton(title: "Profil tuşu: Seç…", target: nil, action: nil)
    let layerClear = NSButton(title: "✕", target: nil, action: nil)
    let seg = NSSegmentedControl(labels: ["Profil 1", "Profil 2"], trackingMode: .selectOne, target: nil, action: nil)
    let assignBtn = NSButton(title: "▶︎ Atamayı başlat", target: nil, action: nil)
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

    // ---- Pencere (varsayılan 350x700) ----
    func buildUI() {
        let title = NSTextField(labelWithString: "Mac Remote")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let exitBtn = NSButton(title: "Çıkış", target: NSApplication.shared, action: #selector(NSApplication.terminate(_:)))
        exitBtn.bezelStyle = .rounded
        exitBtn.setContentHuggingPriority(.required, for: .horizontal)

        popup.addItem(withTitle: "Tüm cihazlar (Apple hariç)")
        popup.target = self; popup.action = #selector(deviceChanged)
        let devLbl = NSTextField(labelWithString: "Cihaz:")
        devLbl.setContentHuggingPriority(.required, for: .horizontal)
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        assignBtn.target = self; assignBtn.action = #selector(toggleAssign)
        assignBtn.bezelStyle = .rounded
        assignBtn.widthAnchor.constraint(equalToConstant: 135).isActive = true
        layerBtn.target = self; layerBtn.action = #selector(pickLayerTapped)
        layerBtn.bezelStyle = .rounded; layerBtn.lineBreakMode = .byTruncatingTail
        layerBtn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        layerClear.target = self; layerClear.action = #selector(clearLayer)
        layerClear.bezelStyle = .rounded; layerClear.toolTip = "Profil tuşunu kaldır"
        layerClear.widthAnchor.constraint(equalToConstant: 34).isActive = true
        seg.target = self; seg.action = #selector(segChanged)
        seg.selectedSegment = 0; seg.segmentDistribution = .fillEqually
        seg.widthAnchor.constraint(equalToConstant: Layout.w).isActive = true
        updateLayerUI()

        var views: [NSView] = [Layout.row([title, exitBtn]), perm,
                               Layout.row([assignBtn, layerBtn, layerClear], spacing: 6), last,
                               Layout.row([devLbl, popup])]
        views.append(contentsOf: [moveSpeed, scrollSpeed, swipeV, swipeH].map { $0.view as NSView })
        views.append(contentsOf: [profLbl, seg] as [NSView])
        let header = NSStackView(views: views)
        header.orientation = .vertical; header.alignment = .leading; header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 12, left: 15, bottom: 0, right: 15)
        header.translatesAutoresizingMaskIntoConstraints = false

        list.orientation = .vertical; list.alignment = .leading; list.spacing = 8
        list.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.documentView = doc

        let content = NSView()
        content.addSubview(header); content.addSubview(scroll)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 15),
            list.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -12)
        ])

        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 700),
                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Mac Remote"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = content
        win.setContentSize(NSSize(width: 350, height: 700))
        win.center()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }

        refreshDisplays()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in refreshDisplays() }
        buildUI()

        // Kayıtlı atamaları yükle (yalnızca mevcut profillere ait olanlar)
        if let d = UserDefaults.standard.data(forKey: "maps2"),
           let saved = try? JSONDecoder().decode([Mapping].self, from: d) {
            for m in saved where m.mouse != "macro" && (m.layer ?? 0) < profileCount {
                addRow(Row(device: m.device, page: m.page, usage: m.usage,
                           k1: m.mouse == nil ? m.k1 : nil, k2: m.k2,
                           mouse: m.mouse, appPath: m.app, layer: m.layer ?? 0, gesture: m.gesture), filter: false)
            }
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
        // İzin durumu yalnızca pencere görünürken yoklanır
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            if self?.win.isVisible == true { self?.refreshPerm() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }

    // Başka bir pencereye/uygulamaya tıklanınca bu pencere kaybolur; ikona tıklayınca tekrar açılır
    func windowDidResignKey(_ n: Notification) {
        if !busy && win.isVisible { hideWindow() }
    }

    func hideWindow() {
        activeBox?.refresh(); activeBox = nil
        win.orderOut(nil)
        lastHide = Date()
    }

    @objc func toggleWindow() {
        if win.isVisible { hideWindow() }
        else if Date().timeIntervalSince(lastHide) > 0.3 { showWindow() }   // ikona tıklamayla az önce gizlendiyse tekrar açma
    }

    @objc func showWindow() {
        refreshPerm()
        if let f = statusItem?.button?.window?.frame, f.width > 0 {
            let vis = (statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            let x = min(max(f.midX - win.frame.width / 2, vis.minX + 8), max(vis.minX + 8, vis.maxX - win.frame.width - 8))
            win.setFrameTopLeftPoint(NSPoint(x: x, y: f.minY - 4))
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    // ---- Satır olayları ----
    func rowFor(_ c: NSControl) -> Row? {
        guard let id = c.identifier?.rawValue else { return nil }
        return rows.first { $0.key == id }
    }

    @objc func actionChanged(_ b: NSPopUpButton) {
        guard let row = rowFor(b) else { return }
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

    // Diyalog açıkken ana pencere odağı kaybetse bile gizlenmez
    func modal<T>(_ body: () -> T) -> T {
        busy = true
        NSApp.activate(ignoringOtherApps: true)
        defer { busy = false; win.makeKeyAndOrderFront(nil) }
        return body()
    }

    @discardableResult
    func chooseApp(for row: Row) -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Açılacak uygulamayı seç"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [UTType.application]
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard modal({ panel.runModal() }) == .OK, let url = panel.url else { return false }
        row.appPath = url.path
        return true
    }

    @discardableResult
    func drawGesture(for row: Row) -> Bool {
        let pad = GesturePad(frame: NSRect(x: 0, y: 0, width: 300, height: 240))
        if let g = row.gesture { pad.load(g) }
        let a = NSAlert()
        a.messageText = "Hareketi çiz"
        a.informativeText = "Kutuda fareyi basılı tutup sürükleyerek hareketi çiz. " +
            "Yeşil nokta başlangıç, kırmızı nokta bitiş. Tuşa basınca hareket, imlecin o anki yerinden başlayarak oynatılır."
        a.accessoryView = pad
        a.addButton(withTitle: "Kaydet"); a.addButton(withTitle: "İptal")
        guard modal({ a.runModal() }) == .alertFirstButtonReturn, !pad.points.isEmpty else { return false }
        row.gesture = pad.points
        return true
    }

    @objc func gestureBtnTapped(_ b: NSButton) {
        if let row = rowFor(b), drawGesture(for: row) { commit() }
    }

    @objc func appBtnTapped(_ b: NSButton) {
        if let row = rowFor(b), chooseApp(for: row) { commit() }
    }

    // ---- Durum / profil ----
    func updateStatusTitle() {
        statusItem?.button?.title = assigning ? " ●" : ""     // profil numarası artık gösterilmez
    }

    func setProfile(_ n: Int, sound: Bool = true) {
        profile = n % profileCount
        profLbl.stringValue = "Aktif profil: Profil \(profile + 1)"
        if sound { NSSound(named: "Pop")?.play() }
    }

    func updateLayerUI() {
        if pickingLayer { layerBtn.title = "Kumandada tuşa bas…"; return }
        if let k = layerKey {
            let parts = k.split(separator: "|").map(String.init)
            if parts.count >= 3, let pg = Int(parts[1]), let us = Int(parts[2]) {
                layerBtn.title = "Profil tuşu: \(sourceName(pg, us))"
                layerBtn.toolTip = "\(parts[0]) · \(sourceName(pg, us))"
                return
            }
        }
        layerBtn.title = "Profil tuşu: Seç…"
        layerBtn.toolTip = "Profil tuşu olacak kumanda tuşuna bas"
    }

    @objc func pickLayerTapped() { pickingLayer = true; updateLayerUI() }

    @objc func clearLayer() {
        layerKey = nil; pickingLayer = false
        UserDefaults.standard.removeObject(forKey: "layerKey")
        setProfile(0, sound: false)
        updateLayerUI()
    }

    @objc func segChanged() { editLayer = seg.selectedSegment; applyFilter() }

    func refreshPerm() {
        let ax = AXIsProcessTrusted(), im = CGPreflightListenEventAccess()
        perm.stringValue = "Erişilebilirlik: \(ax ? "VAR ✅" : "YOK ❌")   Giriş İzleme: \(im ? "VAR ✅" : "YOK ❌")"
            + (hidErr == kIOReturnSuccess ? "" : "   ⚠️ HID açılamadı (\(hidErr))")
        perm.isHidden = ax && im && hidErr == kIOReturnSuccess   // her şey tamamsa satırı gizle
    }

    @objc func toggleAssign() {
        assigning.toggle()
        Hold.stop(); setProfile(0, sound: false); pickingLayer = false; updateLayerUI()
        activeBox?.refresh(); activeBox = nil
        if !assigning { clearEmpty(); commit() }
        assignBtn.title = assigning ? "⏹ Atamayı bitir" : "▶︎ Atamayı başlat"
        last.stringValue = assigning ? "Atama açık: kumandada bir tuşa bas."
                                     : "Atama kapalı. Yalnızca atanmış tuşlar çalışır."
        updateStatusTitle()
    }

    // Menü çubuğu ikonu (bir kez çizilir)
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

    // İkona tıklamak menü değil, doğrudan pencereyi açar/kapatır
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let b = statusItem.button else { return }
        b.image = menuIcon()
        b.imagePosition = .imageLeft
        b.toolTip = "Mac Remote"
        b.target = self; b.action = #selector(toggleWindow)
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

        // Profil tuşu: her basışta sıradaki profile geçer (Profil 1 → 2 → 1)
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

    func addRow(_ row: Row, filter: Bool = true) {
        row.b1.onChange = { [weak self] _ in self?.commit() }
        row.b2.onChange = { [weak self] _ in self?.commit() }
        let id = NSUserInterfaceItemIdentifier(row.key)
        row.act.target = self; row.act.action = #selector(actionChanged(_:))
        row.appBtn.target = self; row.appBtn.action = #selector(appBtnTapped(_:))
        row.gestureBtn.target = self; row.gestureBtn.action = #selector(gestureBtnTapped(_:))
        row.del.target = self; row.del.action = #selector(deleteTapped(_:))
        for c in [row.act, row.appBtn, row.gestureBtn, row.del] as [NSControl] { c.identifier = id }
        rows.append(row)
        list.addArrangedSubview(row.view)
        if filter { applyFilter() }
    }

    @objc func deleteTapped(_ b: NSButton) {
        guard let r = rowFor(b), let i = rows.firstIndex(where: { $0 === r }) else { return }
        rows.remove(at: i)
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
