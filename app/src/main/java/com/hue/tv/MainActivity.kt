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
            for (id in listOf(POWER, BRI, COLOR)) s.getCharacteristic(id)?.let { chars[id] = it }
            prefs.edit().putString("addr", g.device.address).apply()
            runOnUiThread { showPicker(); status.text = "Bağlı · ${chars.size}/3 özellik bulundu" }
        }

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
        failCount = 0; isOn = false; sentBri = -1
    }

    // Yanıt gelmezse kuyruk sonsuza kadar kilitlenmesin
    private val watchdog = Runnable {
        synchronized(queue) { busy = false }
        ui("Lamba yanıt vermedi, devam ediliyor")
        pump()
    }
    private val pumpRun = Runnable { pump() }

    private fun write(id: UUID, b: ByteArray) {
        synchronized(queue) {
            // Renk ve parlaklıkta sadece en son değer önemli: eskileri at (kuyruk şişmesin)
            if (id == COLOR || id == BRI) queue.removeAll { it.first == id }
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
            @Suppress("DEPRECATION") val ok = run { c.value = item.second; g.writeCharacteristic(c) }
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

    private fun u16(v: Double): List<Byte> { val i = (v.coerceIn(0.0, 1.0) * 65535).toInt(); return listOf((i and 0xFF).toByte(), (i shr 8).toByte()) }

    private fun setRgb(color: Int, b2: Int = bri) {
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

    private fun favs(): MutableList<Int> =
        (prefs.getString("favs45", "") ?: "").split(",").mapNotNull { it.toIntOrNull() }.toMutableList()

    private fun saveFavs(l: List<Int>) = prefs.edit().putString("favs45", l.joinToString(",")).apply()

    private fun cell(idx: Int, size: Int, onLong: () -> Unit): LinearLayout {
        val (name, hex) = palette[idx]
        val col = Color.parseColor(hex)
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; gravity = android.view.Gravity.CENTER_HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(size, android.view.ViewGroup.LayoutParams.WRAP_CONTENT)
        }
        val b = button("", col, w = size - 16, h = size - 16) { lastLabel = name; setRgb(col); ui(lastLabel) }
        b.setOnLongClickListener { onLong(); true }
        box.addView(b)
        return box
    }

    private fun showPicker() {
        root.removeAllViews()
        val cols = 15
        val size = (resources.displayMetrics.widthPixels - 160) / cols

        // 1) Favoriler (en üstte)
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
            for (idx in f) favRow.addView(cell(idx, size) {
                val l = favs(); l.remove(idx); saveFavs(l); refreshFavs(); ui("Favoriden çıkarıldı: ${palette[idx].first}")
            })
        }
        refreshFavs()

        // 2) Parlaklık (başlıksız)
        val row = LinearLayout(this)
        for (pct in 10..100 step 10) row.addView(button("%$pct", Color.DKGRAY, w = size - 16) {
            bri = (pct * 254 / 100).coerceAtLeast(1); sentBri = bri; write(BRI, byteArrayOf(bri.toByte()))
        })
        root.addView(row)

        // 3) 45 renk, satırda 15
        root.addView(text("Renkler", 20f))
        val grid = android.widget.GridLayout(this).apply { columnCount = cols }
        for (i in palette.indices) grid.addView(cell(i, size) {
            val l = favs()
            if (l.contains(i)) { l.remove(i); saveFavs(l); refreshFavs(); ui("Favoriden çıkarıldı: ${palette[i].first}") }
            else if (l.size >= cols) ui("Favori satırı dolu (en fazla $cols)")
            else { l.add(i); saveFavs(l); refreshFavs(); ui("Favorilere eklendi: ${palette[i].first}") }
        })
        root.addView(grid)
    }

    override fun onDestroy() { unregisterBond(); stopScan(); gatt?.close(); super.onDestroy() }
}
