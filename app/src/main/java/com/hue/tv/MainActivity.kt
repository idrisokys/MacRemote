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
        root.addView(status); status.text = "Taranıyor..."
        adapter()?.bluetoothLeScanner?.startScan(scanCb); scanning = true
    }

    // ---------- Connect ----------
    private var bondRx: android.content.BroadcastReceiver? = null

    private fun unregisterBond() {
        bondRx?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        bondRx = null
    }

    private fun connect(addr: String) {
        root.removeAllViews(); root.addView(text("Bağlanılıyor...", 28f)); root.addView(status)
        chars.clear(); queue.clear(); busy = false
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
                g.close(); gatt = null; prefs.edit().remove("addr").apply()
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
            busy = false
            when (st) {
                BluetoothGatt.GATT_SUCCESS -> ui("Gönderildi")
                5, 15 -> { ui("Eşleşme gerekiyor ($st), eşleşiliyor... onay çıkarsa kabul edin"); g.device.createBond() }
                else -> ui("Yazma hatası ($st)")
            }
            pump()
        }
    }

    private fun write(id: UUID, b: ByteArray) { synchronized(queue) { queue.addLast(id to b) }; pump() }

    private fun pump() {
        synchronized(queue) {
            if (busy || queue.isEmpty()) return
            val (id, b) = queue.removeFirst()
            val c = chars[id] ?: run { ui("Özellik bulunamadı: ${id.toString().take(8)}"); return }
            @Suppress("DEPRECATION") run { c.value = b; busy = gatt?.writeCharacteristic(c) ?: false }
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
        write(POWER, byteArrayOf(1))
        write(COLOR, (u16(X / sum) + u16(Y / sum)).toByteArray())
        write(BRI, byteArrayOf(b2.toByte()))
    }

    private val handler = Handler(Looper.getMainLooper())

    // En sevilen 50 renk (YouGov, Crayola ve diğer anketlere göre; mavi tonları başta)
    private val palette = listOf(
        "Mavi" to "#1565FF", "Gök Mavisi" to "#87CEEB", "Serulyen" to "#2A7FBA", "Kızılgerdan Yumurtası" to "#1FCECB",
        "Wisteria" to "#C9A0DC", "Koyu Teal" to "#008080", "Yeşil" to "#00A651", "Mor" to "#7B2FF7",
        "Kırmızı" to "#FF0000", "Pembe" to "#FF69B4", "Pastel Pembe" to "#FDDDE6", "Turuncu" to "#FF7F00",
        "Sarı" to "#FFD700", "Lacivert" to "#1B2A6B", "Turkuaz" to "#40E0D0", "Lavanta" to "#B57EDC",
        "Mercan" to "#FF7F50", "Adaçayı" to "#9CAF88", "Zümrüt" to "#50C878", "Nane" to "#98FF98",
        "Gül" to "#FF007F", "Orkide" to "#DA70D6", "Magenta" to "#FF00FF", "Camgöbeği" to "#00FFFF",
        "Kraliyet Mavisi" to "#4169E1", "Kot Mavisi" to "#3F6FB5", "Buz Mavisi" to "#B0E0E6", "Okyanus" to "#00B4D8",
        "Limon Yeşili" to "#A4DE02", "Orman Yeşili" to "#228B22", "Antep Fıstığı" to "#93C572", "Şeftali" to "#FFCBA4",
        "Somon" to "#FA8072", "Kehribar" to "#FFBF00", "Hardal" to "#E1AD01", "Kızıl" to "#DC143C",
        "Toz Gül" to "#D8869A", "Fuşya" to "#FF1493", "Menekşe" to "#8F00FF", "İndigo" to "#5D3FD3",
        "Erik" to "#B05AC0", "Lila" to "#C8A2C8", "Gün Batımı" to "#FF5E3A", "Mandalina" to "#FF9966",
        "Kayısı" to "#FBCEB1", "Sıcak Beyaz" to "#FFC58F", "Beyaz" to "#FFFFFF", "Soğuk Beyaz" to "#C9E2FF",
        "Çam Yeşili" to "#1FA088", "Azur" to "#007FFF"
    )

    private fun favs(): MutableList<Int> =
        (prefs.getString("favs", "") ?: "").split(",").mapNotNull { it.toIntOrNull() }.toMutableList()

    private fun saveFavs(l: List<Int>) = prefs.edit().putString("favs", l.joinToString(",")).apply()

    private fun cell(idx: Int, size: Int, onLong: () -> Unit): LinearLayout {
        val (name, hex) = palette[idx]
        val col = Color.parseColor(hex)
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; gravity = android.view.Gravity.CENTER_HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(size, android.view.ViewGroup.LayoutParams.WRAP_CONTENT)
        }
        val b = button("", col, w = size - 16, h = size - 40) { setRgb(col); ui("${idx + 1} · $name") }
        b.setOnLongClickListener { onLong(); true }
        box.addView(b)
        box.addView(TextView(this).apply { text = "${idx + 1}"; textSize = 14f; setTextColor(Color.WHITE); gravity = android.view.Gravity.CENTER })
        return box
    }

    private fun showPicker() {
        root.removeAllViews()
        val cols = 10
        val size = (resources.displayMetrics.widthPixels - 160) / cols

        // 1) Favoriler (en üstte)
        root.addView(text("Favoriler  (renge uzun basarak ekle / çıkar)", 20f))
        val favRow = LinearLayout(this)
        root.addView(favRow)
        fun refreshFavs() {
            favRow.removeAllViews()
            val f = favs()
            if (f.isEmpty()) favRow.addView(text("Henüz favori yok", 16f).apply { setTextColor(Color.GRAY) })
            for (idx in f) favRow.addView(cell(idx, size) {
                val l = favs(); l.remove(idx); saveFavs(l); refreshFavs(); ui("Favoriden çıkarıldı: ${idx + 1}")
            })
        }
        refreshFavs()

        // 2) Parlaklık
        root.addView(text("Parlaklık", 20f))
        val row = LinearLayout(this)
        for (pct in 10..100 step 10) row.addView(button("%$pct", Color.DKGRAY, w = size - 16) {
            bri = (pct * 254 / 100).coerceAtLeast(1); write(BRI, byteArrayOf(bri.toByte()))
        })
        root.addView(row)

        // 3) 50 renk, satırda 10
        root.addView(text("Renkler", 20f))
        val grid = android.widget.GridLayout(this).apply { columnCount = cols }
        for (i in palette.indices) grid.addView(cell(i, size) {
            val l = favs()
            if (l.contains(i)) { l.remove(i); saveFavs(l); refreshFavs(); ui("Favoriden çıkarıldı: ${i + 1}") }
            else if (l.size >= cols) ui("Favori satırı dolu (en fazla $cols)")
            else { l.add(i); saveFavs(l); refreshFavs(); ui("Favorilere eklendi: ${i + 1}") }
        })
        root.addView(grid)
        root.addView(status)
    }

    override fun onDestroy() { unregisterBond(); stopScan(); gatt?.close(); super.onDestroy() }
}
