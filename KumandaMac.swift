import Cocoa
import IOKit.hid

// ---- Veri ----
struct Mapping: Codable { var src: Int; var dst: Int; var flags: UInt64 }

enum Store {
    static var maps: [Mapping] = {
        guard let d = UserDefaults.standard.data(forKey: "maps"),
              let m = try? JSONDecoder().decode([Mapping].self, from: d) else { return [] }
        return m
    }()
    static func save() { UserDefaults.standard.set(try? JSONEncoder().encode(maps), forKey: "maps") }
}

// ---- Tuş adları ----
let names: [Int: String] = [
    0:"A",11:"B",8:"C",2:"D",14:"E",3:"F",5:"G",4:"H",34:"I",38:"J",40:"K",37:"L",46:"M",
    45:"N",31:"O",35:"P",12:"Q",15:"R",1:"S",17:"T",32:"U",9:"V",13:"W",7:"X",16:"Y",6:"Z",
    18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",29:"0",
    36:"Return",76:"Enter",53:"Esc",49:"Boşluk",48:"Tab",51:"Delete",117:"Sil(ileri)",
    123:"←",124:"→",125:"↓",126:"↑",115:"Home",119:"End",116:"PageUp",121:"PageDown",
    122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12"
]
func keyName(_ c: Int) -> String { names[c] ?? "Tuş#\(c)" }
func flagStr(_ f: UInt64) -> String {
    let g = CGEventFlags(rawValue: f)
    return (g.contains(.maskControl) ? "⌃" : "") + (g.contains(.maskAlternate) ? "⌥" : "")
         + (g.contains(.maskShift) ? "⇧" : "") + (g.contains(.maskCommand) ? "⌘" : "")
}

// ---- Tanılama günlüğü ----
var logLines: [String] = []
var onLog: (() -> Void)?
func logEvent(_ s: String) {
    DispatchQueue.main.async {
        logLines.append(s)
        if logLines.count > 8 { logLines.removeFirst() }
        onLog?()
    }
}

// ---- Olay yakalama ----
enum Mode { case run, learnSrc, learnDst }
var mode = Mode.run
var pendingSrc = 0
var onSrc: ((Int) -> Void)?
var onDst: ((Int, UInt64) -> Void)?
var tap: CFMachPort?
var hidManager: IOHIDManager?
let marker: Int64 = 0x4B554D
let relevant: UInt64 = CGEventFlags([.maskCommand, .maskShift, .maskAlternate, .maskControl]).rawValue

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type.rawValue == 14 { // sistem/medya tuşları
        if let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
            let k = (ns.data1 & 0xFFFF0000) >> 16
            let down = ((ns.data1 & 0xFF00) >> 8) == 0xA
            if down { logEvent("Medya tuşu algılandı (kod \(k))") }
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
    if event.getIntegerValueField(.eventSourceUserData) == marker { return Unmanaged.passUnretained(event) }
    let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let isDown = (type == .keyDown)
    if isDown { logEvent("Tuş algılandı: \(keyName(code)) (kod \(code))") }

    switch mode {
    case .learnSrc:
        if isDown { mode = .run; DispatchQueue.main.async { onSrc?(code) } }
        return nil
    case .learnDst:
        if isDown {
            let f = event.flags.rawValue & relevant
            mode = .run
            DispatchQueue.main.async { onDst?(code, f) }
        }
        return nil
    case .run:
        guard let m = Store.maps.first(where: { $0.src == code }) else { return Unmanaged.passUnretained(event) }
        let s = CGEventSource(stateID: .hidSystemState)
        if let e = CGEvent(keyboardEventSource: s, virtualKey: CGKeyCode(m.dst), keyDown: isDown) {
            e.flags = CGEventFlags(rawValue: m.flags)
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
        return nil
    }
}

// ---- Arayüz ----
final class AppDelegate: NSObject, NSApplicationDelegate {
    var win: NSWindow!
    let status = NSTextField(wrappingLabelWithString: "Hazır.")
    let list = NSStackView()
    let diag = NSTextField(wrappingLabelWithString: "(henüz sinyal yok)")

    func applicationDidFinishLaunching(_ n: Notification) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let ax = AXIsProcessTrustedWithOptions(opts)
        var im = CGPreflightListenEventAccess()
        if !im { im = CGRequestListenEventAccess() }
        startHID()

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << 14)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                callback: callback, userInfo: nil)
        if let t = tap {
            let rl = CFMachPortCreateRunLoopSource(nil, t, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), rl, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
        } else {
            status.stringValue = "İzin yok! Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik ve Giriş İzleme bölümlerinde bu uygulamayı (veya Terminal'i) etkinleştirip yeniden başlat."
        }

        let perm = NSTextField(wrappingLabelWithString:
            "Erişilebilirlik izni: \(ax ? "VAR ✅" : "YOK ❌")   Giriş İzleme izni: \(im ? "VAR ✅" : "YOK ❌")")
        let diagTitle = NSTextField(labelWithString: "Tanılama (gelen her sinyal burada görünür):")
        diag.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        onLog = { [weak self] in self?.diag.stringValue = logLines.joined(separator: "\n") }

        let add = NSButton(title: "Yeni atama ekle", target: self, action: #selector(addTapped))
        let cancel = NSButton(title: "İptal", target: self, action: #selector(cancelTapped))
        let row = NSStackView(views: [add, cancel]); row.spacing = 8
        let root = NSStackView(views: [perm, row, status, list, diagTitle, diag])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 6

        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Kumanda Ayar"
        win.contentView = root
        win.center(); win.makeKeyAndOrderFront(nil)
        refresh()
    }

    func startHID() {
        let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(hid, nil)
        IOHIDManagerRegisterInputValueCallback(hid, { _, _, _, value in
            let el = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(el)
            let usage = IOHIDElementGetUsage(el)
            guard page == 0x07 || page == 0x0C, usage > 0, usage < 0xFFFF,
                  IOHIDValueGetIntegerValue(value) == 1 else { return }
            let dev = IOHIDElementGetDevice(el)
            let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
            logEvent("HID [\(name)] sayfa 0x\(String(page, radix: 16)) kullanım 0x\(String(usage, radix: 16))")
        }, nil)
        IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = hid
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    @objc func addTapped() {
        status.stringValue = "1/2: Kumandada atamak istediğin tuşa bas."
        mode = .learnSrc
        onSrc = { [weak self] code in
            pendingSrc = code
            self?.status.stringValue = "2/2: \(keyName(code)) yerine çalışacak tuşa veya kombinasyona bas (örn. ⌘V)."
            mode = .learnDst
        }
        onDst = { [weak self] code, flags in
            Store.maps.removeAll { $0.src == pendingSrc }
            Store.maps.append(Mapping(src: pendingSrc, dst: code, flags: flags))
            Store.save()
            self?.status.stringValue = "Kaydedildi: \(keyName(pendingSrc)) → \(flagStr(flags))\(keyName(code))"
            self?.refresh()
        }
    }

    @objc func cancelTapped() { mode = .run; status.stringValue = "İptal edildi." }

    @objc func removeTapped(_ b: NSButton) {
        guard b.tag < Store.maps.count else { return }
        Store.maps.remove(at: b.tag); Store.save(); refresh()
    }

    func refresh() {
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (i, m) in Store.maps.enumerated() {
            let l = NSTextField(labelWithString: "\(keyName(m.src))  →  \(flagStr(m.flags))\(keyName(m.dst))")
            let d = NSButton(title: "Sil", target: self, action: #selector(removeTapped(_:))); d.tag = i
            let r = NSStackView(views: [l, d]); r.spacing = 12
            list.addArrangedSubview(r)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
