import Cocoa
import IOKit.hid

// ---------- Veri ----------
struct Mapping: Codable { var device: String; var page: Int; var usage: Int; var k1: Int; var k2: Int? }

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
func postKey(_ code: Int, down: Bool, flags: CGEventFlags) {
    let s = CGEventSource(stateID: .hidSystemState)
    if let e = CGEvent(keyboardEventSource: s, virtualKey: CGKeyCode(code), keyDown: down) {
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}
func perform(_ m: Mapping) {
    let f: CGEventFlags = modFlag[m.k1] ?? []
    postKey(m.k1, down: true, flags: f)
    if let k2 = m.k2 {
        postKey(k2, down: true, flags: f)
        postKey(k2, down: false, flags: f)
    }
    postKey(m.k1, down: false, flags: [])
}

// ---------- Kumanda dinleme (HID) ----------
var onHID: ((String, Int, Int) -> Void)?
var hidManager: IOHIDManager?
var activeBox: KeyBox?

func startHID() -> IOReturn {
    let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(hid, nil)
    IOHIDManagerRegisterInputValueCallback(hid, { _, _, _, value in
        let el = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(el))
        let usage = Int(IOHIDElementGetUsage(el))
        guard page == 0x07 || page == 0x0C, usage > 0, usage < 0xFFFF,
              IOHIDValueGetIntegerValue(value) == 1 else { return }
        let dev = IOHIDElementGetDevice(el)
        let vendor = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        if vendor == 0x05AC { return } // Apple (Mac klavyesi/trackpad) yok sayılır
        let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "Bilinmeyen"
        onHID?(name, page, usage)
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
    let label: NSTextField
    let b1 = KeyBox(frame: .zero), b2 = KeyBox(frame: .zero)
    let del = NSButton(title: "Sil", target: nil, action: nil)
    let view: NSStackView
    var key: String { "\(device)|\(page)|\(usage)" }

    init(device: String, page: Int, usage: Int, k1: Int?, k2: Int?) {
        self.device = device; self.page = page; self.usage = usage
        label = NSTextField(labelWithString: "\(device) · \(sourceName(page, usage))")
        label.widthAnchor.constraint(equalToConstant: 200).isActive = true
        label.lineBreakMode = .byTruncatingTail
        b1.code = k1; b2.code = k2
        let plus = NSTextField(labelWithString: "+")
        view = NSStackView(views: [label, b1, plus, b2, del])
        view.spacing = 8
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
    let last = NSTextField(wrappingLabelWithString: "Son sinyal: (henüz yok)")
    let list = NSStackView()
    var rows: [Row] = []
    var table: [String: Mapping] = [:]

    func applicationDidFinishLaunching(_ n: Notification) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let ax = AXIsProcessTrustedWithOptions(opts)
        var im = CGPreflightListenEventAccess()
        if !im { im = CGRequestListenEventAccess() }
        let r = startHID()
        perm.stringValue = "Erişilebilirlik: \(ax ? "VAR ✅" : "YOK ❌")   Giriş İzleme: \(im ? "VAR ✅" : "YOK ❌")"
            + (r == kIOReturnSuccess ? "" : "   ⚠️ HID açılamadı (\(r))")

        let hint = NSTextField(wrappingLabelWithString:
            "1) Kumandada bir tuşa bas, aşağıda satırı belirir.\n" +
            "2) Kutuya tıkla, klavyeden tuş bas. Tek kutu doluysa o tuş çalışır.\n" +
            "3) İki kutu doluysa 1. tuş basılı tutulup 2. tuşa basılır (ör. Command + V = Yapıştır).")
        hint.widthAnchor.constraint(equalToConstant: 540).isActive = true

        let root = NSStackView(views: [perm, hint, last, list])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 8

        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Kumanda Ayar"
        win.contentView = root
        win.center(); win.makeKeyAndOrderFront(nil)

        // Kayıtlı atamaları yükle
        if let d = UserDefaults.standard.data(forKey: "maps2"),
           let saved = try? JSONDecoder().decode([Mapping].self, from: d) {
            for m in saved { addRow(Row(device: m.device, page: m.page, usage: m.usage, k1: m.k1, k2: m.k2)) }
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

        onHID = { [weak self] dev, page, usage in self?.handle(dev, page, usage) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func handle(_ dev: String, _ page: Int, _ usage: Int) {
        let key = "\(dev)|\(page)|\(usage)"
        last.stringValue = "Son sinyal: \(dev) · \(sourceName(page, usage))"
        if let row = rows.first(where: { $0.key == key }) {
            row.flash()
        } else {
            addRow(Row(device: dev, page: page, usage: usage, k1: nil, k2: nil))
        }
        if let m = table[key] { perform(m) }
    }

    func addRow(_ row: Row) {
        row.b1.onChange = { [weak self] c in self?.commit() }
        row.b2.onChange = { [weak self] c in self?.commit() }
        row.del.target = self; row.del.action = #selector(deleteTapped(_:))
        row.del.identifier = NSUserInterfaceItemIdentifier(row.key)
        rows.append(row)
        list.addArrangedSubview(row.view)
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
            let k1 = r.b1.code ?? r.b2.code
            let k2 = r.b1.code == nil ? nil : r.b2.code
            if let k1 = k1 {
                table[r.key] = Mapping(device: r.device, page: r.page, usage: r.usage, k1: k1, k2: k2)
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
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
