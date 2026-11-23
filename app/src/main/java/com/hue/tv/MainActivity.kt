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
    private fun connect(addr: String) {
        root.removeAllViews(); root.addView(text("Bağlanılıyor...", 28f)); root.addView(status)
        chars.clear(); queue.clear(); busy = false
        gatt?.close()
        val dev = adapter()!!.getRemoteDevice(addr)
        gatt = dev.connectGatt(this, false, object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, st: Int, ns: Int) {
                if (ns == BluetoothProfile.STATE_CONNECTED) g.discoverServices()
                else runOnUiThread { prefs.edit().remove("addr").apply(); showScan(); status.text = "Bağlantı kesildi. Tekrar seçin." }
            }
            override fun onServicesDiscovered(g: BluetoothGatt, st: Int) {
                val s = g.getService(SVC)
                if (s == null) { runOnUiThread { prefs.edit().remove("addr").apply(); showScan(); status.text = "Bu cihaz Hue değil." }; return }
                for (id in listOf(POWER, BRI, TEMP, COLOR)) s.getCharacteristic(id)?.let { chars[id] = it }
                prefs.edit().putString("addr", addr).apply()
                runOnUiThread { showPicker() }
            }
            override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, st: Int) {
                busy = false
                if (st != BluetoothGatt.GATT_SUCCESS) ui("Yazma hatası ($st) — ışık eşleşmeye açık mı?")
                pump()
            }
        })
    }

    private fun write(id: UUID, b: ByteArray) { synchronized(queue) { queue.addLast(id to b) }; pump() }

    private fun pump() {
        synchronized(queue) {
            if (busy || queue.isEmpty()) return
            val (id, b) = queue.removeFirst()
            val c = chars[id] ?: return
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

    private fun setWhite(mired: Int) {
        write(POWER, byteArrayOf(1))
        write(TEMP, byteArrayOf((mired and 0xFF).toByte(), (mired shr 8).toByte()))
        write(BRI, byteArrayOf(bri.toByte()))
    }


    // ---------- Effects (uygulama tarafında) ----------
    private val handler = Handler(Looper.getMainLooper())
    private var effect: Runnable? = null
    private var step = 0

    private fun stopEffect() { effect?.let { handler.removeCallbacks(it) }; effect = null }

    private fun hsv(h: Float, s: Float, v: Float = 1f) = Color.HSVToColor(floatArrayOf((h % 360f + 360f) % 360f, s, v))

    private fun runEffect(delayMs: Long, next: () -> Pair<Int, Int>) {
        stopEffect(); step = 0
        val r = object : Runnable {
            override fun run() { val (c, b) = next(); setRgb(c, b); step++; handler.postDelayed(this, delayMs) }
        }
        effect = r; handler.post(r)
    }

    private fun effectsRow(): LinearLayout {
        val row = LinearLayout(this)
        row.addView(button("Mum", Color.parseColor("#E65100"), w = 170) {
            runEffect(600) { hsv(28f + Random.nextFloat() * 10f, 0.9f) to Random.nextInt(100, 221) } })
        row.addView(button("Şömine", Color.parseColor("#BF360C"), w = 170) {
            runEffect(500) { hsv(5f + Random.nextFloat() * 30f, 1f) to Random.nextInt(120, 255) } })
        row.addView(button("Döngü", Color.parseColor("#6A1B9A"), w = 170) {
            runEffect(1000) { hsv(step * 15f, 1f) to bri } })
        row.addView(button("Okyanus", Color.parseColor("#0277BD"), w = 170) {
            runEffect(1500) { hsv(180f + Random.nextFloat() * 60f, 0.8f + Random.nextFloat() * 0.2f) to bri } })
        row.addView(button("Aurora", Color.parseColor("#2E7D32"), w = 170) {
            runEffect(2000) { (if (Random.nextBoolean()) hsv(110f + Random.nextFloat() * 60f, 1f) else hsv(260f + Random.nextFloat() * 40f, 0.9f)) to bri } })
        row.addView(button("Kıvılcım", Color.parseColor("#F9A825"), Color.BLACK, 170) {
            runEffect(800) { hsv(Random.nextFloat() * 360f, 0.5f + Random.nextFloat() * 0.5f) to Random.nextInt(150, 255) } })
        row.addView(button("Durdur", Color.DKGRAY, w = 170) { stopEffect() })
        return row
    }

    private fun showPicker() {
        root.removeAllViews()
        root.addView(text("Hue Renk Seç", 32f))
        val hsv = FloatArray(3)
        for (sat in floatArrayOf(1f, 0.6f, 0.3f)) {
            val row = LinearLayout(this)
            for (h in 0 until 360 step 30) {
                hsv[0] = h.toFloat(); hsv[1] = sat; hsv[2] = 1f
                val col = Color.HSVToColor(hsv)
                row.addView(button("", col, h = 90, w = 120) { stopEffect(); setRgb(col) })
            }
            root.addView(HorizontalScrollView(this).apply { addView(row) })
        }
        val row2 = LinearLayout(this)
        row2.addView(button("Sıcak Beyaz", Color.parseColor("#FFB46B"), Color.BLACK, 220) { stopEffect(); setWhite(400) })
        row2.addView(button("Soğuk Beyaz", Color.parseColor("#CFE6FF"), Color.BLACK, 220) { stopEffect(); setWhite(200) })
        row2.addView(button("Aç", Color.parseColor("#2E7D32")) { write(POWER, byteArrayOf(1)) })
        row2.addView(button("Kapat", Color.parseColor("#C62828")) { stopEffect(); write(POWER, byteArrayOf(0)) })
        root.addView(row2)
        root.addView(text("Efektler", 20f))
        root.addView(HorizontalScrollView(this).apply { addView(effectsRow()) })
        root.addView(text("Parlaklık", 20f))
        val row3 = LinearLayout(this)
        for ((l, v) in listOf("%25" to 64, "%50" to 127, "%75" to 190, "%100" to 254))
            row3.addView(button(l, Color.DKGRAY) { bri = v; write(BRI, byteArrayOf(v.toByte())) })
        root.addView(row3)
        root.addView(button("Başka Işık Seç", Color.parseColor("#37474F"), w = 300) {
            stopEffect(); prefs.edit().remove("addr").apply(); gatt?.close(); showScan()
        })
        root.addView(status)
    }

    override fun onDestroy() { stopEffect(); stopScan(); gatt?.close(); super.onDestroy() }
}
