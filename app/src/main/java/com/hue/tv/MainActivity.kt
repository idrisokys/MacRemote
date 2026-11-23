package com.hue.tv

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import kotlin.random.Random
import android.widget.*
import java.util.UUID
import kotlin.math.pow

@SuppressLint("MissingPermission")
class MainActivity : Activity() {
    companion object {
        val SVC: UUID = UUID.fromString("932c32bd-0000-47a2-835a-a8d455b859dd")
        fun ch(n: Int): UUID = UUID.fromString("932c32bd-000$n-47a2-835a-a8d455b859dd")
        val POWER = ch(2); val BRI = ch(3); val TEMP = ch(4); val COLOR = ch(5)
    }

    private lateinit var prefs: android.content.SharedPreferences
    private lateinit var root: LinearLayout
    private lateinit var status: TextView
    private var gatt: BluetoothGatt? = null
    private val chars = HashMap<UUID, BluetoothGattCharacteristic>()
    private val queue = ArrayDeque<Pair<UUID, ByteArray>>()
    private var busy = false
    private var failCount = 0
    private var lastWriteAt = 0L
    private var isOn = false      // lambaya güç komutu gönderildi mi
    private var sentBri = -1      // lambaya son gönderilen parlaklık
    private var lastLabel = ""
    private var lastColor: Int? = null                    // uygulamanın son gönderdiği renk
    private var readWait: MutableSet<UUID>? = null     // henüz okunmamış özellikler
    private val readVals = HashMap<UUID, ByteArray?>()
    private var stateCb: ((Map<UUID, ByteArray?>) -> Unit)? = null
    private val gapMs = 150L      // iki yazma arası minimum süre (renk hızı sınırı)
    private var bri = 254
    private var scanning = false
    private val seen = HashSet<String>()

    override fun onCreate(s: Bundle?) {
        super.onCreate(s)
        prefs = getSharedPreferences("hue", MODE_PRIVATE)
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#111111")); setPadding(64, 40, 64, 40)
        }
        setContentView(ScrollView(this).apply { addView(root) })
        status = text("", 20f)
        val need = if (Build.VERSION.SDK_INT >= 31)
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        if (need.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) start()
        else requestPermissions(need, 1)
    }

    override fun onRequestPermissionsResult(c: Int, p: Array<out String>, r: IntArray) {
        if (r.isNotEmpty() && r.all { it == PackageManager.PERMISSION_GRANTED }) start()
        else { root.removeAllViews(); root.addView(text("Bluetooth izni gerekli. Uygulamayı yeniden açıp izin verin.", 24f)) }
    }

    private fun adapter(): BluetoothAdapter? = (getSystemService(BLUETOOTH_SERVICE) as BluetoothManager).adapter

    private fun start() {
        val a = adapter()
        if (a == null || !a.isEnabled) {
            root.removeAllViews(); root.addView(text("Bluetooth kapalı veya bu TV'de yok.", 24f)); return
        }
        val saved = prefs.getString("addr", null)
        if (saved != null) connect(saved) else showScan()
    }

    // ---------- UI helpers ----------
    private fun text(t: String, size: Float) = TextView(this).apply {
        text = t; textSize = size; setTextColor(Color.WHITE); setPadding(0, 8, 0, 8)
    }

    private fun button(label: String, bg: Int, fg: Int = Color.WHITE, w: Int = 150, h: Int = 90, onClick: () -> Unit) =
        Button(this).apply {
            text = label; setTextColor(fg); isFocusable = true
            minWidth = 0; minHeight = 0; minimumWidth = 0; minimumHeight = 0; setPadding(0, 0, 0, 0)
            val d = GradientDrawable().apply { setColor(bg); cornerRadius = 16f }
            val f = GradientDrawable().apply { setColor(bg); cornerRadius = 16f; setStroke(8, Color.WHITE) }
            background = StateListDrawable().apply {
                addState(intArrayOf(android.R.attr.state_focused), f); addState(intArrayOf(), d)
            }
            layoutParams = LinearLayout.LayoutParams(w, h).apply { setMargins(8, 8, 8, 8) }
            setOnClickListener { onClick() }
        }

    private fun addStatus(parent: LinearLayout, lp: LinearLayout.LayoutParams? = null) {
        (status.parent as? android.view.ViewGroup)?.removeView(status)
        if (lp != null) parent.addView(status, lp) else parent.addView(status)
    }

    private fun ui(msg: String) = runOnUiThread { status.text = msg }

    // ---------- Scan ----------
    private val scanCb = object : ScanCallback() {
        override fun onScanResult(type: Int, r: ScanResult) {
            val name = r.scanRecord?.deviceName ?: r.device.name ?: return
            if (!seen.add(r.device.address)) return
            val hue = name.contains("hue", true)
            runOnUiThread {
                val b = button((if (hue) "★ " else "") + name + "  (" + r.device.address + ")",
                    if (hue) Color.parseColor("#1E88E5") else Color.parseColor("#37474F"), w = 900) {
                    stopScan(); connect(r.device.address)
                }
                root.addView(b, if (hue) 2 else root.childCount - 1)
            }
        }
    }

    private fun stopScan() {
        if (scanning) { adapter()?.bluetoothLeScanner?.stopScan(scanCb); scanning = false }
    }

    private fun showScan() {
        stopScan(); seen.clear()
        root.removeAllViews()
        root.addView(text("Hue ışığını seç", 32f))
        root.addView(text("Işığın pairing modunda olması gerekir (fabrika reseti / Hue uygulamasından silinmiş). ★ işaretliler Hue.", 18f))
        addStatus(root); status.text = "Taranıyor..."
        adapter()?.bluetoothLeScanner?.startScan(scanCb); scanning = true
    }

    // ---------- Connect ----------
    private var bondRx: android.content.BroadcastReceiver? = null

    private fun unregisterBond() {
        bondRx?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        bondRx = null
    }

    private fun connect(addr: String) {
        root.removeAllViews(); root.addView(text("Bağlanılıyor...", 28f)); addStatus(root)
        chars.clear(); resetWriteState()
        gatt?.close(); gatt = null
        unregisterBond()
        val dev = adapter()!!.getRemoteDevice(addr)
        if (dev.bondState == BluetoothDevice.BOND_BONDED) { openGatt(dev); return }
        ui("Eşleşiliyor... TV'de onay çıkarsa kabul edin.")
        var sawBonding = false
        val rx = object : android.content.BroadcastReceiver() {
            @Suppress("DEPRECATION")
            override fun onReceive(c: android.content.Context, i: android.content.Intent) {
                val d = i.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
                if (d?.address != addr) return
                when (i.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)) {
                    BluetoothDevice.BOND_BONDING -> sawBonding = true
                    BluetoothDevice.BOND_BONDED -> { unregisterBond(); openGatt(dev) }
                    BluetoothDevice.BOND_NONE -> if (sawBonding) { unregisterBond(); ui("Eşleşme olmadı, eşleşmesiz deneniyor..."); openGatt(dev) }
                }
            }
        }
        bondRx = rx
        registerReceiver(rx, android.content.IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED))
        if (!dev.createBond()) { unregisterBond(); openGatt(dev) }
        handler.postDelayed({ if (bondRx != null) { unregisterBond(); ui("Eşleşme zaman aşımı, deneniyor..."); openGatt(dev) } }, 20000)
    }

    private fun openGatt(dev: BluetoothDevice) {
        if (gatt != null) return
        gatt = dev.connectGatt(this, false, gattCb, BluetoothDevice.TRANSPORT_LE)
    }

    private val gattCb = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, st: Int, ns: Int) {
            if (ns == BluetoothProfile.STATE_CONNECTED) {
                ui("Bağlandı, servisler aranıyor...")
                handler.postDelayed({ g.discoverServices() }, 600)
            } else runOnUiThread {
                g.close(); gatt = null; resetWriteState(); prefs.edit().remove("addr").apply()
                showScan(); status.text = "Bağlantı kesildi (kod $st). Tekrar seçin."
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, st: Int) {
            val s = g.getService(SVC)
            if (s == null) {
                val list = g.services.joinToString("\n") { it.uuid.toString().take(8) }
                runOnUiThread { prefs.edit().remove("addr").apply(); showScan(); status.text = "Hue servisi yok. Bulunan servisler:\n$list" }
                return
            }
            for (id in listOf(POWER, BRI, COLOR, TEMP)) s.getCharacteristic(id)?.let { chars[id] = it }
            prefs.edit().putString("addr", g.device.address).apply()
            runOnUiThread { showPicker(); status.text = "Bağlı · ${chars.size}/4 özellik bulundu" }
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, st: Int) { onReadDone(c, c.value, st) }

        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, st: Int) { onReadDone(c, value, st) }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, st: Int) {
            handler.removeCallbacks(watchdog)
            synchronized(queue) { busy = false }
            when (st) {
                BluetoothGatt.GATT_SUCCESS -> { failCount = 0; ui(if (lastLabel.isEmpty()) "Gönderildi" else "✓ Gönderildi · $lastLabel") }
                5, 15 -> { isOn = false; sentBri = -1; ui("Eşleşme gerekiyor ($st), eşleşiliyor... onay çıkarsa kabul edin"); g.device.createBond() }
                else -> ui("Yazma hatası ($st)")
            }
            pump()
        }
    }

    private fun resetWriteState() {
        handler.removeCallbacks(watchdog); handler.removeCallbacks(pumpRun)
        synchronized(queue) { queue.clear(); busy = false }
        readWait = null; stateCb = null
        failCount = 0; isOn = false; sentBri = -1
    }

    // Yanıt gelmezse kuyruk sonsuza kadar kilitlenmesin
    private val watchdog = Runnable {
        synchronized(queue) { busy = false }
        ui("Lamba yanıt vermedi, devam ediliyor")
        if (readWait != null) finishRead()
        pump()
    }
    private val pumpRun = Runnable { pump() }

    private fun onReadDone(c: BluetoothGattCharacteristic, v: ByteArray?, st: Int) {
        handler.removeCallbacks(watchdog)
        synchronized(queue) { busy = false }
        var done = false
        synchronized(readVals) {
            val w = readWait
            if (w != null && w.remove(c.uuid)) {
                readVals[c.uuid] = if (st == BluetoothGatt.GATT_SUCCESS) v?.copyOf() else null
                done = w.isEmpty()
            }
        }
        if (done) finishRead()
        pump()
    }

    private fun finishRead() {
        var cb: ((Map<UUID, ByteArray?>) -> Unit)? = null
        var snap: Map<UUID, ByteArray?> = emptyMap()
        synchronized(readVals) { cb = stateCb; stateCb = null; readWait = null; snap = HashMap(readVals) }
        val c = cb; val m = snap
        runOnUiThread { c?.invoke(m) }
    }

    // Lambanın renk (xy), beyaz ton (mired) ve parlaklık değerlerini okur.
    // Okuma istekleri kuyruktaki yazmalardan sonra çalışır.
    private fun readState(cb: (Map<UUID, ByteArray?>) -> Unit) {
        val ids = listOf(COLOR, TEMP, BRI).filter { chars[it] != null }
        if (ids.isEmpty()) { cb(emptyMap()); return }
        synchronized(readVals) { readVals.clear(); readWait = ids.toMutableSet(); stateCb = cb }
        ids.forEach { write(it, ByteArray(0)) }
    }

    private fun write(id: UUID, b: ByteArray) {
        synchronized(queue) {
            // Renk ve parlaklıkta sadece en son değer önemli: eskileri at (kuyruk şişmesin)
            if (b.isNotEmpty() && (id == COLOR || id == BRI || id == TEMP)) queue.removeAll { it.first == id && it.second.isNotEmpty() }
            queue.addLast(id to b)
        }
        pump()
    }

    private fun pump() {
        synchronized(queue) {
            if (busy || queue.isEmpty()) return
            val wait = lastWriteAt + gapMs - SystemClock.uptimeMillis()
            if (wait > 0) { handler.removeCallbacks(pumpRun); handler.postDelayed(pumpRun, wait); return }
            val item = queue.removeFirst()
            val c = chars[item.first]
            val g = gatt
            if (c == null || g == null) { ui("Özellik bulunamadı: ${item.first.toString().take(8)}"); return }
            busy = true                       // ÖNCE işaretle: callback çok hızlı gelirse yarışma olmasın
            lastWriteAt = SystemClock.uptimeMillis()
            @Suppress("DEPRECATION") val ok =
                if (item.second.isEmpty()) g.readCharacteristic(c)
                else run { c.value = item.second; g.writeCharacteristic(c) }
            if (ok) {
                handler.removeCallbacks(watchdog); handler.postDelayed(watchdog, 2500)
            } else {
                busy = false
                if (++failCount <= 5) { queue.addFirst(item); handler.removeCallbacks(pumpRun); handler.postDelayed(pumpRun, 300) }
                else { failCount = 0; ui("Yazma başlatılamadı, atlandı") }
            }
        }
    }

    // ---------- Color ----------
    private fun lin(c: Float) = if (c > 0.04045f) ((c + 0.055f) / 1.055f).toDouble().pow(2.4) else (c / 12.92f).toDouble()

    // Lambanın xy değerini ekranda gösterilecek RGB'ye çevirir (setRgb'nin tersi, tam parlaklıkta)
    private fun xyToColor(x: Double, y: Double): Int {
        if (y < 1e-4) return Color.WHITE
        val Y = 1.0; val X = Y / y * x; val Z = Y / y * (1 - x - y)
        var r = X * 1.656492 - Y * 0.354851 - Z * 0.255038
        var g = -X * 0.707196 + Y * 1.655397 + Z * 0.036152
        var b = X * 0.051713 - Y * 0.121364 + Z * 1.011530
        r = maxOf(r, 0.0); g = maxOf(g, 0.0); b = maxOf(b, 0.0)
        val m = maxOf(r, g, b)
        if (m <= 0.0) return Color.WHITE
        r /= m; g /= m; b /= m
        fun enc(c: Double): Int {
            val v = if (c > 0.0031308) 1.055 * c.pow(1 / 2.4) - 0.055 else 12.92 * c
            return (v.coerceIn(0.0, 1.0) * 255 + 0.5).toInt()
        }
        return Color.rgb(enc(r), enc(g), enc(b))
    }

    private fun u16le(b: ByteArray, o: Int) = (b[o].toInt() and 0xFF) or ((b[o + 1].toInt() and 0xFF) shl 8)

    private fun hex6(c: Int) = String.format("%06X", c and 0xFFFFFF)

    // Beyaz ton (mired) -> xy (Planck eğrisi yaklaşımı, 1667K-25000K)
    private fun miredToXy(mired: Int): Pair<Double, Double> {
        val t = (1_000_000.0 / mired).coerceIn(1667.0, 25000.0)
        val x = if (t <= 4000) -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
                else -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
        val y = when {
            t <= 2222 -> -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
            t <= 4000 -> -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
            else -> 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
        }
        return x to y
    }

    private fun u16(v: Double): List<Byte> { val i = (v.coerceIn(0.0, 1.0) * 65535).toInt(); return listOf((i and 0xFF).toByte(), (i shr 8).toByte()) }

    private fun setRgb(color: Int, b2: Int = bri) {
        lastColor = color
        val r = lin(Color.red(color) / 255f); val g = lin(Color.green(color) / 255f); val b = lin(Color.blue(color) / 255f)
        val X = r * 0.664511 + g * 0.154324 + b * 0.162028
        val Y = r * 0.283881 + g * 0.668433 + b * 0.047685
        val Z = r * 0.000088 + g * 0.072310 + b * 0.986039
        val sum = X + Y + Z
        if (!isOn) { write(POWER, byteArrayOf(1)); isOn = true }
        write(COLOR, (u16(X / sum) + u16(Y / sum)).toByteArray())
        if (sentBri != b2) { write(BRI, byteArrayOf(b2.toByte())); sentBri = b2 }
    }

    private val handler = Handler(Looper.getMainLooper())

    // Ressamların en sevdiği 45 renk (klasik sanatçı pigmentleri); satırda 15
    private val palette = listOf(
        // 1. satır: mavi - yeşil
        "Ultramarin Mavi" to "#2A3BE0", "Kobalt Mavisi" to "#0047AB", "Serulyen Mavisi" to "#2A7FBA", "Prusya Mavisi" to "#1B5E8C", "Gök Mavisi" to "#87CEEB",
        "Kraliyet Mavisi" to "#4169E1", "Azur" to "#007FFF", "Turkuaz" to "#30D5C8", "Viridian" to "#40826D", "Zümrüt Yeşili" to "#50C878",
        "Yaprak Yeşili" to "#3CB043", "Sap Yeşili" to "#4F7942", "Zeytin Yeşili" to "#6B8E23", "Çam Yeşili" to "#01796F", "Adaçayı" to "#9CAF88",
        // 2. satır: sarı - turuncu - kırmızı
        "Limon Sarısı" to "#FFF44F", "Kadmiyum Sarısı" to "#FFE600", "Napoli Sarısı" to "#FADA5E", "Altın Sarısı" to "#FFD700", "Hint Sarısı" to "#E3A857",
        "Sarı Oker" to "#CC7722", "Kehribar" to "#FFBF00", "Kadmiyum Turuncusu" to "#ED872D", "Mandalina" to "#FF9966", "Yanık Siena" to "#E97451",
        "Vermilyon" to "#E34234", "Kadmiyum Kırmızısı" to "#E30022", "Alizarin Kırmızısı" to "#E32636", "Karmin" to "#C41E3A", "Venedik Kırmızısı" to "#C80815",
        // 3. satır: pembe - mor - beyaz tonları
        "Madder Gülü" to "#E8527A", "Kinakridon Magenta" to "#D6338A", "Fuşya" to "#FF1493", "Gül Kurusu" to "#D8869A", "Menekşe Moru" to "#8F00FF",
        "İndigo" to "#5D3FD3", "Mangan Moru" to "#9966CC", "Lavanta" to "#B57EDC", "Eflatun" to "#E0B0FF", "Erik" to "#B05AC0",
        "Şeftali" to "#FFCBA4", "Sıcak Beyaz" to "#FFC58F", "Titanyum Beyazı" to "#FFFFFF", "Soğuk Beyaz" to "#C9E2FF", "Ham Siena" to "#B5651D"
    )

    // Favori: renk (RRGGBB) + parlaklık (1-254, 0 = değiştirme) + beyaz ton (mired, 0 = renk modu)
    private data class Fav(val hex: String, val bri: Int = 0, val mired: Int = 0) {
        fun encode() = "$hex;$bri;$mired"
    }

    private fun parseFav(t: String): Fav? {
        val p = t.split(";")
        if (p[0].length != 6) return null
        return Fav(p[0], p.getOrNull(1)?.toIntOrNull() ?: 0, p.getOrNull(2)?.toIntOrNull() ?: 0)
    }

    private fun favs(): MutableList<Fav> {
        val v2 = prefs.getString("favs2", null)
        if (v2 != null) return v2.split(",").mapNotNull { parseFav(it) }.toMutableList()
        // eski sürümden geçiş: palet indeksleri
        return (prefs.getString("favs45", "") ?: "").split(",").mapNotNull { it.toIntOrNull() }
            .mapNotNull { palette.getOrNull(it)?.second?.removePrefix("#")?.let { h -> Fav(h) } }.toMutableList()
    }

    private fun saveFavs(l: List<Fav>) = prefs.edit().putString("favs2", l.joinToString(",") { it.encode() }).apply()

    private fun label(f: Fav): String {
        val base = when {
            f.mired > 0 -> "Beyaz ${1_000_000 / f.mired / 50 * 50}K"
            else -> palette.firstOrNull { it.second.removePrefix("#").equals(f.hex, true) }?.first ?: "Özel renk #${f.hex}"
        }
        return if (f.bri > 0) "$base · %${(f.bri * 100 / 254).coerceAtLeast(1)}" else base
    }

    private fun applyFav(f: Fav) {
        lastLabel = label(f)
        val col = Color.parseColor("#${f.hex}")
        lastColor = col
        if (f.bri > 0) { bri = f.bri; sentBri = -1 }      // kayıtlı parlaklığı mutlaka gönder
        if (f.mired > 0 && chars[TEMP] != null) {
            if (!isOn) { write(POWER, byteArrayOf(1)); isOn = true }
            write(TEMP, byteArrayOf((f.mired and 0xFF).toByte(), (f.mired shr 8).toByte()))
            if (sentBri != bri) { write(BRI, byteArrayOf(bri.toByte())); sentBri = bri }
        } else setRgb(col)
        ui(lastLabel)
    }

    private fun cell(hex: String, size: Int, onTap: () -> Unit, onLong: () -> Unit): LinearLayout {
        val col = Color.parseColor("#$hex")
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; gravity = android.view.Gravity.CENTER_HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(size, android.view.ViewGroup.LayoutParams.WRAP_CONTENT)
        }
        val b = button("", col, w = size - 16, h = size - 16) { onTap() }
        b.setOnLongClickListener { onLong(); true }
        box.addView(b)
        return box
    }

    private fun showPicker() {
        root.removeAllViews()
        val cols = 15
        val size = (resources.displayMetrics.widthPixels - 160) / cols

        // 1) Favoriler (en üstte) + durum yazısı sağında
        val head = LinearLayout(this).apply { gravity = android.view.Gravity.CENTER_VERTICAL }
        head.addView(text("Favoriler  (renge uzun basarak ekle / çıkar)", 20f))
        addStatus(head, LinearLayout.LayoutParams(
            android.view.ViewGroup.LayoutParams.WRAP_CONTENT, android.view.ViewGroup.LayoutParams.WRAP_CONTENT).apply { leftMargin = 48 })
        root.addView(head)
        val favRow = LinearLayout(this)
        root.addView(favRow)
        fun refreshFavs() {
            favRow.removeAllViews()
            val f = favs()
            if (f.isEmpty()) favRow.addView(text("Henüz favori yok", 16f).apply { setTextColor(Color.GRAY) })
            for (fav in f) favRow.addView(cell(fav.hex, size, { applyFav(fav) }) {
                val l = favs(); l.remove(fav); saveFavs(l); refreshFavs(); ui("Favoriden çıkarıldı: ${label(fav)}")
            })
        }
        fun addFav(fav: Fav) {
            val l = favs()
            when {
                l.contains(fav) -> ui("Zaten favoride: ${label(fav)}")
                l.size >= cols -> ui("Favori satırı dolu (en fazla $cols)")
                else -> { l.add(fav); saveFavs(l); refreshFavs(); ui("Favorilere eklendi: ${label(fav)}") }
            }
        }
        refreshFavs()

        // 2) Parlaklık (başlıksız) + lambanın mevcut rengini / beyaz tonunu / parlaklığını favoriye kaydet
        val row = LinearLayout(this)
        for (pct in 10..100 step 10) row.addView(button("%$pct", Color.DKGRAY, w = size - 16) {
            bri = (pct * 254 / 100).coerceAtLeast(1); sentBri = bri; write(BRI, byteArrayOf(bri.toByte()))
        })
        row.addView(button("★ Mevcut rengi kaydet", Color.parseColor("#B8860B"), w = size * 4 - 16) {
            ui("Lambanın durumu okunuyor...")
            val lc = lastColor; val lb = bri
            readState { m ->
                val cb = m[COLOR]; val tb = m[TEMP]; val bb = m[BRI]
                val xy = if (cb != null && cb.size >= 4) (u16le(cb, 0) / 65535.0 to u16le(cb, 2) / 65535.0) else null
                val mired = if (tb != null && tb.size >= 2) u16le(tb, 0) else 0
                val br = if (bb != null && bb.isNotEmpty()) (bb[0].toInt() and 0xFF).coerceIn(1, 254) else 0
                val miredOk = mired in 100..1000
                // xy, beyaz tonun xy'sine yakınsa lamba beyaz modunda kabul edilir
                val white = miredOk && (xy == null || miredToXy(mired).let { c -> Math.hypot(xy.first - c.first, xy.second - c.second) } < 0.02)
                val fav: Fav? = when {
                    white -> miredToXy(mired).let { Fav(hex6(xyToColor(it.first, it.second)), br, mired) }
                    xy != null -> Fav(hex6(xyToColor(xy.first, xy.second)), br, 0)
                    lc != null -> Fav(hex6(lc), lb, 0)          // lamba okunamazsa son gönderilen renk
                    else -> null
                }
                if (fav == null) ui("Lamba okunamadı") else addFav(fav)
            }
        })
        root.addView(row)

        // 3) 45 renk, satırda 15
        root.addView(text("Renkler", 20f))
        val grid = android.widget.GridLayout(this).apply { columnCount = cols }
        for (i in palette.indices) {
            val hex = palette[i].second.removePrefix("#")
            val pf = Fav(hex)
            grid.addView(cell(hex, size, { applyFav(pf) }) {
                val l = favs()
                if (l.contains(pf)) { l.remove(pf); saveFavs(l); refreshFavs(); ui("Favoriden çıkarıldı: ${label(pf)}") }
                else addFav(pf)
            })
        }
        root.addView(grid)
    }

    override fun onDestroy() { unregisterBond(); stopScan(); gatt?.close(); super.onDestroy() }
}
