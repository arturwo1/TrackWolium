package __PACKAGE__

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import android.os.IBinder
import android.util.Base64
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

class P2pService : Service() {
  @Volatile private var running = false
  private var server: ServerSocket? = null

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    if (running) return START_STICKY
    val dir = Sync.dir(applicationContext)
    val enabled = File(dir, "p2p").exists() || File(dir, "peers.json").exists()
    if (!enabled || !File(dir, "consent").exists()) {
      stopSelf()
      return START_NOT_STICKY
    }
    startForegroundCompat()
    running = true
    Thread { serve() }.start()
    return START_STICKY
  }

  override fun onDestroy() {
    running = false
    try {
      server?.close()
    } catch (_: Exception) {
    }
    server = null
    super.onDestroy()
  }

  private fun startForegroundCompat() {
    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= 26) {
      nm.createNotificationChannel(NotificationChannel("p2p", Sync.text(this, "p2pNotifChannel"), NotificationManager.IMPORTANCE_LOW))
    }
    val open = PendingIntent.getActivity(this, 2, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    val n: Notification = NotificationCompat.Builder(this, "p2p")
      .setSmallIcon(applicationInfo.icon)
      .setContentTitle(Sync.text(this, "p2pNotifText"))
      .setContentIntent(open)
      .setOngoing(true)
      .setOnlyAlertOnce(true)
      .setPriority(NotificationCompat.PRIORITY_LOW)
      .setCategory(NotificationCompat.CATEGORY_SERVICE)
      .build()
    if (Build.VERSION.SDK_INT >= 34) startForeground(8, n, 1073741824) else startForeground(8, n)
  }

  private fun serve() {
    var bound: ServerSocket? = null
    for (attempt in 0 until 10) {
      if (!running) return
      try {
        bound = ServerSocket().apply {
          reuseAddress = true
          bind(java.net.InetSocketAddress(InetAddress.getByName("0.0.0.0"), PORT), 8)
        }
        break
      } catch (_: Exception) {
        try {
          Thread.sleep(150)
        } catch (_: Exception) {
        }
      }
    }
    val s = bound ?: return
    server = s
    while (running) {
      try {
        val c = s.accept()
        Thread { handle(c) }.start()
      } catch (_: Exception) {
        break
      }
    }
  }

  private fun handle(c: Socket) {
    try {
      c.soTimeout = 10000
      val input = c.getInputStream()
      val buf = ByteArray(8192)
      val raw = java.io.ByteArrayOutputStream()
      var hdrEnd = -1
      while (raw.size() < 65536) {
        val n = input.read(buf)
        if (n <= 0) break
        raw.write(buf, 0, n)
        val s = String(raw.toByteArray(), Charsets.ISO_8859_1)
        hdrEnd = s.indexOf("\r\n\r\n")
        if (hdrEnd >= 0) break
      }
      if (hdrEnd < 0) {
        c.getOutputStream().write(http(400, "{\"error\":\"bad_request\"}").toByteArray(Charsets.UTF_8))
        return
      }
      val initBytes = raw.toByteArray()
      val headerText = String(initBytes, 0, hdrEnd, Charsets.ISO_8859_1)
      val lines = headerText.split("\r\n")
      val parts = lines.firstOrNull()?.split(" ") ?: emptyList()
      var auth = ""
      var contentLen = 0
      for (l in lines.drop(1)) {
        val i = l.indexOf(':')
        if (i <= 0) continue
        val k = l.substring(0, i).trim().lowercase(Locale.ROOT)
        val v = l.substring(i + 1).trim()
        if (k == "authorization") auth = v
        else if (k == "content-length") contentLen = (v.toIntOrNull() ?: 0).coerceIn(0, 8 * 1024 * 1024)
      }
      val bodyStart = hdrEnd + 4
      val bodyOut = java.io.ByteArrayOutputStream()
      if (initBytes.size > bodyStart) {
        bodyOut.write(initBytes, bodyStart, initBytes.size - bodyStart)
      }
      while (bodyOut.size() < contentLen) {
        val n = input.read(buf)
        if (n <= 0) break
        bodyOut.write(buf, 0, n)
      }
      val reqBytes = bodyOut.toByteArray()
      val reqBody = if (contentLen > 0 && reqBytes.isNotEmpty()) {
        String(reqBytes, 0, minOf(contentLen, reqBytes.size), Charsets.UTF_8)
      } else ""
      val method = parts.firstOrNull() ?: ""
      val target = (parts.getOrNull(1) ?: "").substringBefore('?')
      val remoteIp = c.inetAddress?.hostAddress ?: ""
      val resp = route(method, target, auth, reqBody, remoteIp)
      c.getOutputStream().write(resp.toByteArray(Charsets.UTF_8))
      c.getOutputStream().flush()
    } catch (_: Exception) {
    } finally {
      try {
        c.close()
      } catch (_: Exception) {
      }
    }
  }

  private fun deviceId(): String {
    val dir = Sync.dir(applicationContext)
    val f = File(dir, "device_id")
    return try {
      val text = if (f.exists()) f.readText().trim() else ""
      if (text.length == 36) text else {
        val id = UUID.randomUUID().toString()
        dir.mkdirs()
        f.writeText(id)
        id
      }
    } catch (_: Exception) {
      UUID.randomUUID().toString()
    }
  }

  private fun deviceName(): String {
    val dir = Sync.dir(applicationContext)
    try {
      val f = File(dir, "device_name")
      val text = if (f.exists()) f.readText().trim() else ""
      if (text.isNotEmpty()) return text
    } catch (_: Exception) {
    }
    return Sync.deviceName(applicationContext)
  }

  private fun findPeerByToken(token: String): JSONObject? {
    if (token.isEmpty()) return null
    return try {
      val f = File(Sync.dir(applicationContext), "peers.json")
      if (!f.exists()) return null
      val arr = JSONArray(f.readText())
      for (i in 0 until arr.length()) {
        val obj = arr.optJSONObject(i) ?: continue
        if (obj.optString("token", "") == token) return obj
      }
      null
    } catch (_: Exception) {
      null
    }
  }

  private fun touchPeerSync(peerId: String, name: String, plat: String, host: String, port: Int, nowSec: Long) {
    try {
      val f = File(Sync.dir(applicationContext), "peers.json")
      if (!f.exists()) return
      val arr = JSONArray(f.readText())
      for (i in 0 until arr.length()) {
        val obj = arr.optJSONObject(i) ?: continue
        if (obj.optString("id", "") == peerId) {
          obj.put("name", name)
          obj.put("platform", plat)
          if (host.isNotEmpty()) obj.put("host", host)
          obj.put("port", port)
          obj.put("lastSync", nowSec)
        }
      }
      f.writeText(arr.toString())
    } catch (_: Exception) {
    }
  }

  private fun importSnapshot(peerId: String, peer: JSONObject, body: JSONObject, remoteHost: String) {
    importSnapshotForContext(applicationContext, peerId, peer, body, remoteHost)
  }

  private fun exportSnapshot(): String = exportSnapshotForContext(applicationContext)

  private fun route(method: String, path: String, auth: String, reqBody: String, remoteIp: String): String {
    if (method == "GET" && path == "/p2p/hello") {
      val ver = try {
        applicationContext.packageManager.getPackageInfo(applicationContext.packageName, 0).versionName ?: "1.0.0"
      } catch (_: Exception) {
        "1.0.0"
      }
      return http(
        200,
        JSONObject()
          .put("id", deviceIdForContext(applicationContext))
          .put("name", deviceNameForContext(applicationContext))
          .put("platform", "android")
          .put("version", ver)
          .toString()
      )
    }
    if (method == "POST" && path == "/p2p/pair") {
      return http(403, "{\"error\":\"open_wolium_to_pair\"}")
    }
    if (method == "POST" && path == "/p2p/sync") {
      val token = if (auth.startsWith("Bearer ")) auth.substring(7).trim() else ""
      val peer = findPeerByToken(token) ?: return http(401, "{\"error\":\"unauthorized\"}")
      try {
        val body = if (reqBody.isEmpty()) JSONObject() else JSONObject(reqBody)
        importSnapshot(peer.getString("id"), peer, body, remoteIp)
      } catch (_: Exception) {
        return http(400, "{\"error\":\"bad_request\"}")
      }
      try {
        Sync.run(applicationContext)
      } catch (_: Exception) {
      }
      return http(200, exportSnapshot())
    }
    return http(404, "{\"error\":\"not_found\"}")
  }

  private fun http(status: Int, body: String): String {
    val text = when (status) {
      200 -> "OK"
      401 -> "Unauthorized"
      403 -> "Forbidden"
      404 -> "Not Found"
      else -> "Bad Request"
    }
    val bytes = body.toByteArray(Charsets.UTF_8).size
    return "HTTP/1.1 $status $text\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: $bytes\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n$body"
  }

  companion object {
    const val PORT = 9096

    fun apply(ctx: Context, on: Boolean) {
      val intent = Intent(ctx, P2pService::class.java)
      if (on) {
        if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(intent) else ctx.startService(intent)
      } else {
        ctx.stopService(intent)
      }
    }

    private fun deviceIdForContext(ctx: Context): String {
      val dir = Sync.dir(ctx)
      val f = File(dir, "device_id")
      return try {
        val text = if (f.exists()) f.readText().trim() else ""
        if (text.length == 36) text else {
          val id = UUID.randomUUID().toString()
          dir.mkdirs()
          f.writeText(id)
          id
        }
      } catch (_: Exception) {
        UUID.randomUUID().toString()
      }
    }

    private fun deviceNameForContext(ctx: Context): String {
      val dir = Sync.dir(ctx)
      try {
        val f = File(dir, "device_name")
        val text = if (f.exists()) f.readText().trim() else ""
        if (text.isNotEmpty()) return text
      } catch (_: Exception) {
      }
      return Sync.deviceName(ctx)
    }

    private fun touchPeerSyncForContext(ctx: Context, peerId: String, name: String, plat: String, host: String, port: Int, nowSec: Long) {
      try {
        val f = File(Sync.dir(ctx), "peers.json")
        if (!f.exists()) return
        val arr = JSONArray(f.readText())
        for (i in 0 until arr.length()) {
          val obj = arr.optJSONObject(i) ?: continue
          if (obj.optString("id", "") == peerId) {
            obj.put("name", name)
            obj.put("platform", plat)
            if (host.isNotEmpty()) obj.put("host", host)
            obj.put("port", port)
            obj.put("lastSync", nowSec)
          }
        }
        f.writeText(arr.toString())
      } catch (_: Exception) {
      }
    }

    private fun isBadTitle(title: String, domain: String): Boolean {
      val t = title.trim().lowercase(Locale.ROOT)
      if (t.isEmpty()) return true
      val ld = domain.lowercase(Locale.ROOT)
      val bare = if (ld.startsWith("www.")) ld.substring(4) else ld
      if (t == ld || t == "www.$ld" || t == bare) return true
      if (t.startsWith("http://") || t.startsWith("https://") || t.startsWith("about:") || t.startsWith("file://") ||
        t.startsWith("chrome:") || t.startsWith("edge:") || t.startsWith("opera:") || t.startsWith("moz-extension:")
      ) return true
      if (t.startsWith("$ld/") || t.startsWith("www.$ld/") || t.startsWith("$bare/") || t.startsWith("$ld:") || t.startsWith("www.$ld:")) return true
      if (!t.contains(' ') && Regex("^[a-z0-9-]+(\\.[a-z0-9-]+)+(:\\d+)?(/.*)?$").matches(t)) return true
      return false
    }

    fun ensureSchema(db: SQLiteDatabase) {
      db.execSQL("CREATE TABLE IF NOT EXISTS usage(day TEXT NOT NULL, app TEXT NOT NULL, state INTEGER NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(day, app, state)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS timeline(day TEXT NOT NULL, slot INTEGER NOT NULL, app TEXT NOT NULL, state INTEGER NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(day, slot, app, state)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS sessions(app TEXT NOT NULL, start INTEGER NOT NULL, stop INTEGER NOT NULL, state INTEGER NOT NULL, PRIMARY KEY(app, start)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS apps(app TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL DEFAULT '') WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS browser_usage(day TEXT NOT NULL, browser TEXT NOT NULL, domain TEXT NOT NULL, ms INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '', url TEXT NOT NULL DEFAULT '', PRIMARY KEY(day, browser, domain)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS browser_timeline(day TEXT NOT NULL, slot INTEGER NOT NULL, browser TEXT NOT NULL, domain TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', ms INTEGER NOT NULL, PRIMARY KEY(day, slot, browser, domain)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS day_stats(day TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(day, kind)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS app_stats(day TEXT NOT NULL, app TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(day, app, kind)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS res(day TEXT NOT NULL, slot INTEGER NOT NULL, app TEXT NOT NULL, cpu INTEGER NOT NULL DEFAULT 0, ram INTEGER NOT NULL DEFAULT 0, n INTEGER NOT NULL DEFAULT 0, peak INTEGER NOT NULL DEFAULT 0, ior INTEGER NOT NULL DEFAULT 0, iow INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(day, slot, app)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS sysmon(ts INTEGER NOT NULL, kind TEXT NOT NULL, a INTEGER NOT NULL, b INTEGER NOT NULL, PRIMARY KEY(ts, kind)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS afk(day TEXT NOT NULL, slot INTEGER NOT NULL, app TEXT NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(day, slot, app)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS sys_events(ts INTEGER NOT NULL, kind TEXT NOT NULL, duration_ms INTEGER NOT NULL DEFAULT 0, extra TEXT NOT NULL DEFAULT '', PRIMARY KEY(ts, kind)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL, host TEXT NOT NULL DEFAULT '', port INTEGER NOT NULL DEFAULT 9096, last_sync INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS remote_usage(device TEXT NOT NULL, day TEXT NOT NULL, app TEXT NOT NULL, state INTEGER NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(device, day, app, state)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS remote_timeline(device TEXT NOT NULL, day TEXT NOT NULL, slot INTEGER NOT NULL, app TEXT NOT NULL, state INTEGER NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(device, day, slot, app, state)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS remote_apps(device TEXT NOT NULL, app TEXT NOT NULL, name TEXT NOT NULL, path TEXT NOT NULL DEFAULT '', PRIMARY KEY(device, app)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS remote_browser_usage(device TEXT NOT NULL, day TEXT NOT NULL, browser TEXT NOT NULL, domain TEXT NOT NULL, ms INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '', url TEXT NOT NULL DEFAULT '', PRIMARY KEY(device, day, browser, domain)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS remote_browser_timeline(device TEXT NOT NULL, day TEXT NOT NULL, slot INTEGER NOT NULL, browser TEXT NOT NULL, domain TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', ms INTEGER NOT NULL, PRIMARY KEY(device, day, slot, browser, domain)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS remote_day_stats(device TEXT NOT NULL, day TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(device, day, kind)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS remote_app_stats(device TEXT NOT NULL, day TEXT NOT NULL, app TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(device, day, app, kind)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS remote_slot_stats(device TEXT NOT NULL, day TEXT NOT NULL, slot INTEGER NOT NULL, app TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(device, day, slot, app, kind)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS remote_res(device TEXT NOT NULL, day TEXT NOT NULL, slot INTEGER NOT NULL, app TEXT NOT NULL, cpu INTEGER NOT NULL DEFAULT 0, ram INTEGER NOT NULL DEFAULT 0, n INTEGER NOT NULL DEFAULT 0, peak INTEGER NOT NULL DEFAULT 0, ior INTEGER NOT NULL DEFAULT 0, iow INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(device, day, slot, app)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS remote_sysmon(device TEXT NOT NULL, ts INTEGER NOT NULL, kind TEXT NOT NULL, a INTEGER NOT NULL, b INTEGER NOT NULL, PRIMARY KEY(device, ts, kind)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS remote_afk(device TEXT NOT NULL, day TEXT NOT NULL, slot INTEGER NOT NULL, app TEXT NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(device, day, slot, app)) WITHOUT ROWID")
      db.execSQL("CREATE TABLE IF NOT EXISTS remote_sys_events(device TEXT NOT NULL, ts INTEGER NOT NULL, kind TEXT NOT NULL, duration_ms INTEGER NOT NULL DEFAULT 0, extra TEXT NOT NULL DEFAULT '', PRIMARY KEY(device, ts, kind)) WITHOUT ROWID")
    }

    private fun safeSeg(s: String): String = s.replace(Regex("[^a-zA-Z0-9._-]"), "_")

    private fun iconFileName(app: String): String {
      val enc = Base64.encodeToString(app.toByteArray(Charsets.UTF_8), Base64.URL_SAFE or Base64.NO_WRAP).replace("=", "")
      return "$enc.png"
    }

    fun importSnapshotForContext(ctx: Context, peerId: String, peer: JSONObject, body: JSONObject, remoteHost: String) {
      val devInfo = body.optJSONObject("device")
      val rawName = devInfo?.optString("name", "")?.trim() ?: ""
      val oldName = peer.optString("name", "").trim()
      val name = if (rawName.isNotEmpty()) rawName else if (oldName.isNotEmpty()) oldName else Sync.text(ctx, "deviceDefault")
      val plat = devInfo?.optString("platform", "")?.trim()?.ifEmpty { peer.optString("platform", "unknown") } ?: "unknown"
      val host = if (remoteHost.isNotEmpty()) remoteHost else peer.optString("host", "")
      val port = peer.optInt("port", PORT)
      val nowSec = System.currentTimeMillis() / 1000L

      val dir = Sync.dir(ctx)
      dir.mkdirs()
      val iconDir = File(dir, "remote_icons/${safeSeg(peerId)}")
      val db = SQLiteDatabase.openOrCreateDatabase(File(dir, "usage.db"), null)
      try {
        db.enableWriteAheadLogging()
        ensureSchema(db)
        db.beginTransaction()
        try {
          db.execSQL("INSERT OR REPLACE INTO devices(id, name, platform, host, port, last_sync) VALUES(?, ?, ?, ?, ?, ?)", arrayOf<Any>(peerId, name, plat, host, port, nowSec))
          body.optJSONArray("usage")?.let { list ->
            val st = db.compileStatement("INSERT OR REPLACE INTO remote_usage(device, day, app, state, ms) VALUES(?, ?, ?, ?, ?)")
            for (i in 0 until list.length()) {
              val item = list.optJSONObject(i) ?: continue
              st.clearBindings()
              st.bindString(1, peerId)
              st.bindString(2, item.optString("day", ""))
              st.bindString(3, item.optString("app", ""))
              st.bindLong(4, item.optLong("state", 0))
              st.bindLong(5, item.optLong("ms", 0))
              st.execute()
            }
            st.close()
          }
          body.optJSONArray("timeline")?.let { list ->
            val st = db.compileStatement("INSERT OR REPLACE INTO remote_timeline(device, day, slot, app, state, ms) VALUES(?, ?, ?, ?, ?, ?)")
            for (i in 0 until list.length()) {
              val item = list.optJSONObject(i) ?: continue
              st.clearBindings()
              st.bindString(1, peerId)
              st.bindString(2, item.optString("day", ""))
              st.bindLong(3, item.optLong("slot", 0))
              st.bindString(4, item.optString("app", ""))
              st.bindLong(5, item.optLong("state", 0))
              st.bindLong(6, item.optLong("ms", 0))
              st.execute()
            }
            st.close()
          }
          body.optJSONArray("apps")?.let { list ->
            val st = db.compileStatement("INSERT INTO remote_apps(device, app, name, path) VALUES(?, ?, ?, ?) ON CONFLICT(device, app) DO UPDATE SET name = excluded.name, path = CASE WHEN excluded.path != '' THEN excluded.path ELSE remote_apps.path END")
            for (i in 0 until list.length()) {
              val item = list.optJSONObject(i) ?: continue
              val appId = item.optString("app", "")
              if (appId.isEmpty()) continue
              var iconPath = ""
              val b64 = item.optString("icon", "")
              if (b64.isNotEmpty()) {
                try {
                  val bytes = Base64.decode(b64, Base64.DEFAULT)
                  if (bytes.isNotEmpty()) {
                    iconDir.mkdirs()
                    val f = File(iconDir, iconFileName(appId))
                    f.writeBytes(bytes)
                    iconPath = f.absolutePath
                  }
                } catch (_: Exception) {
                  iconPath = ""
                }
              }
              st.clearBindings()
              st.bindString(1, peerId)
              st.bindString(2, appId)
              st.bindString(3, item.optString("name", ""))
              st.bindString(4, iconPath)
              st.execute()
            }
            st.close()
          }
          body.optJSONArray("browser_usage")?.let { list ->
            val st = db.compileStatement("INSERT OR REPLACE INTO remote_browser_usage(device, day, browser, domain, ms, title, url) VALUES(?, ?, ?, ?, ?, ?, ?)")
            for (i in 0 until list.length()) {
              val item = list.optJSONObject(i) ?: continue
              val dom = item.optString("domain", "")
              val rawT = item.optString("title", "")
              val cleanT = if (isBadTitle(rawT, dom)) "" else rawT
              st.clearBindings()
              st.bindString(1, peerId)
              st.bindString(2, item.optString("day", ""))
              st.bindString(3, item.optString("browser", ""))
              st.bindString(4, dom)
              st.bindLong(5, item.optLong("ms", 0))
              st.bindString(6, cleanT)
              st.bindString(7, item.optString("url", ""))
              st.execute()
            }
            st.close()
          }
          body.optJSONArray("browser_timeline")?.let { list ->
            val st = db.compileStatement("INSERT OR REPLACE INTO remote_browser_timeline(device, day, slot, browser, domain, title, ms) VALUES(?, ?, ?, ?, ?, ?, ?)")
            for (i in 0 until list.length()) {
              val item = list.optJSONObject(i) ?: continue
              val dom = item.optString("domain", "")
              val rawT = item.optString("title", "")
              val cleanT = if (isBadTitle(rawT, dom)) "" else rawT
              st.clearBindings()
              st.bindString(1, peerId)
              st.bindString(2, item.optString("day", ""))
              st.bindLong(3, item.optLong("slot", 0))
              st.bindString(4, item.optString("browser", ""))
              st.bindString(5, dom)
              st.bindString(6, cleanT)
              st.bindLong(7, item.optLong("ms", 0))
              st.execute()
            }
            st.close()
          }
          body.optJSONArray("day_stats")?.let { list ->
            val st = db.compileStatement("INSERT OR REPLACE INTO remote_day_stats(device, day, kind, n) VALUES(?, ?, ?, ?)")
            for (i in 0 until list.length()) {
              val item = list.optJSONObject(i) ?: continue
              st.clearBindings()
              st.bindString(1, peerId)
              st.bindString(2, item.optString("day", ""))
              st.bindString(3, item.optString("kind", ""))
              st.bindLong(4, item.optLong("n", 0))
              st.execute()
            }
            st.close()
          }
          body.optJSONArray("app_stats")?.let { list ->
            val st = db.compileStatement("INSERT OR REPLACE INTO remote_app_stats(device, day, app, kind, n) VALUES(?, ?, ?, ?, ?)")
            for (i in 0 until list.length()) {
              val item = list.optJSONObject(i) ?: continue
              st.clearBindings()
              st.bindString(1, peerId)
              st.bindString(2, item.optString("day", ""))
              st.bindString(3, item.optString("app", ""))
              st.bindString(4, item.optString("kind", ""))
              st.bindLong(5, item.optLong("n", 0))
              st.execute()
            }
            st.close()
          }
          body.optJSONArray("slot_stats")?.let { list ->
            val st = db.compileStatement("INSERT OR REPLACE INTO remote_slot_stats(device, day, slot, app, kind, n) VALUES(?, ?, ?, ?, ?, ?)")
            for (i in 0 until list.length()) {
              val item = list.optJSONObject(i) ?: continue
              st.clearBindings()
              st.bindString(1, peerId)
              st.bindString(2, item.optString("day", ""))
              st.bindLong(3, item.optLong("slot", 0))
              st.bindString(4, item.optString("app", ""))
              st.bindString(5, item.optString("kind", ""))
              st.bindLong(6, item.optLong("n", 0))
              st.execute()
            }
            st.close()
          }
          body.optJSONArray("res")?.let { list ->
            val st = db.compileStatement("INSERT OR REPLACE INTO remote_res(device, day, slot, app, cpu, ram, n, peak, ior, iow) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
            for (i in 0 until list.length()) {
              val item = list.optJSONObject(i) ?: continue
              st.clearBindings()
              st.bindString(1, peerId)
              st.bindString(2, item.optString("day", ""))
              st.bindLong(3, item.optLong("slot", 0))
              st.bindString(4, item.optString("app", ""))
              st.bindLong(5, item.optLong("cpu", 0))
              st.bindLong(6, item.optLong("ram", 0))
              st.bindLong(7, item.optLong("n", 0))
              st.bindLong(8, item.optLong("peak", 0))
              st.bindLong(9, item.optLong("ior", 0))
              st.bindLong(10, item.optLong("iow", 0))
              st.execute()
            }
            st.close()
          }
          body.optJSONArray("sysmon")?.let { list ->
            val st = db.compileStatement("INSERT OR REPLACE INTO remote_sysmon(device, ts, kind, a, b) VALUES(?, ?, ?, ?, ?)")
            for (i in 0 until list.length()) {
              val item = list.optJSONObject(i) ?: continue
              st.clearBindings()
              st.bindString(1, peerId)
              st.bindLong(2, item.optLong("ts", 0))
              st.bindString(3, item.optString("kind", ""))
              st.bindLong(4, item.optLong("a", 0))
              st.bindLong(5, item.optLong("b", 0))
              st.execute()
            }
            st.close()
          }
          body.optJSONArray("afk")?.let { list ->
            val st = db.compileStatement("INSERT OR REPLACE INTO remote_afk(device, day, slot, app, ms) VALUES(?, ?, ?, ?, ?)")
            for (i in 0 until list.length()) {
              val item = list.optJSONObject(i) ?: continue
              st.clearBindings()
              st.bindString(1, peerId)
              st.bindString(2, item.optString("day", ""))
              st.bindLong(3, item.optLong("slot", 0))
              st.bindString(4, item.optString("app", ""))
              st.bindLong(5, item.optLong("ms", 0))
              st.execute()
            }
            st.close()
          }
          body.optJSONArray("sys_events")?.let { list ->
            val st = db.compileStatement("INSERT OR REPLACE INTO remote_sys_events(device, ts, kind, duration_ms, extra) VALUES(?, ?, ?, ?, ?)")
            for (i in 0 until list.length()) {
              val item = list.optJSONObject(i) ?: continue
              st.clearBindings()
              st.bindString(1, peerId)
              st.bindLong(2, item.optLong("ts", 0))
              st.bindString(3, item.optString("kind", ""))
              st.bindLong(4, item.optLong("duration_ms", 0))
              st.bindString(5, item.optString("extra", ""))
              st.execute()
            }
            st.close()
          }
          db.setTransactionSuccessful()
        } finally {
          db.endTransaction()
        }
        db.rawQuery("PRAGMA wal_checkpoint(TRUNCATE)", null).close()
      } finally {
        db.close()
      }
      touchPeerSyncForContext(ctx, peerId, name, plat, host, port, nowSec)
    }

    fun exportSnapshotForContext(ctx: Context): String {
      val sinceMs = System.currentTimeMillis() - 30L * 86400000L
      val fromDay = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(sinceMs))
      val sinceTs = sinceMs / 1000L
      val usage = JSONArray()
      val timeline = JSONArray()
      val apps = JSONArray()
      val browser = JSONArray()
      val browserTimeline = JSONArray()
      val dayStats = JSONArray()
      val appStats = JSONArray()
      val slotStats = JSONArray()
      val res = JSONArray()
      val sysmon = JSONArray()
      val afk = JSONArray()
      val sysEvents = JSONArray()
      val dbFile = File(Sync.dir(ctx), "usage.db")
      if (dbFile.exists()) {
        val db = SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READONLY)
        try {
          try {
            db.rawQuery("SELECT day, app, state, ms FROM usage WHERE day >= ?", arrayOf(fromDay)).use { c ->
              while (c.moveToNext()) usage.put(JSONObject().put("day", c.getString(0)).put("app", c.getString(1)).put("state", c.getInt(2)).put("ms", c.getLong(3)))
            }
          } catch (_: Exception) {}
          try {
            db.rawQuery("SELECT day, slot, app, state, ms FROM timeline WHERE day >= ?", arrayOf(fromDay)).use { c ->
              while (c.moveToNext()) timeline.put(JSONObject().put("day", c.getString(0)).put("slot", c.getInt(1)).put("app", c.getString(2)).put("state", c.getInt(3)).put("ms", c.getLong(4)))
            }
          } catch (_: Exception) {}
          try {
            var iconBudget = 0
            var iconCount = 0
            db.rawQuery("SELECT a.app, a.name, a.path, COALESCE(u.ms, 0) AS total_ms FROM apps a LEFT JOIN (SELECT app, SUM(ms) AS ms FROM usage GROUP BY app) u ON u.app = a.app ORDER BY total_ms DESC", null).use { c ->
              while (c.moveToNext()) {
                val obj = JSONObject().put("app", c.getString(0)).put("name", c.getString(1))
                val p = c.getString(2) ?: ""
                if (p.isNotEmpty() && iconCount < 180 && iconBudget < 2000000) {
                  val f = File(p)
                  if (f.exists() && f.length() in 1..65536) {
                    val bytes = f.readBytes()
                    if (iconBudget + bytes.size <= 2000000) {
                      obj.put("icon", Base64.encodeToString(bytes, Base64.NO_WRAP))
                      iconBudget += bytes.size
                      iconCount++
                    }
                  }
                }
                apps.put(obj)
              }
            }
          } catch (_: Exception) {}
          try {
            db.rawQuery("SELECT day, browser, domain, ms, title, url FROM browser_usage WHERE day >= ?", arrayOf(fromDay)).use { c ->
              while (c.moveToNext()) browser.put(JSONObject().put("day", c.getString(0)).put("browser", c.getString(1)).put("domain", c.getString(2)).put("ms", c.getLong(3)).put("title", c.getString(4) ?: "").put("url", c.getString(5) ?: ""))
            }
          } catch (_: Exception) {}
          try {
            db.rawQuery("SELECT day, slot, browser, domain, title, ms FROM browser_timeline WHERE day >= ?", arrayOf(fromDay)).use { c ->
              while (c.moveToNext()) browserTimeline.put(JSONObject().put("day", c.getString(0)).put("slot", c.getInt(1)).put("browser", c.getString(2)).put("domain", c.getString(3)).put("title", c.getString(4) ?: "").put("ms", c.getLong(5)))
            }
          } catch (_: Exception) {}
          try {
            db.rawQuery("SELECT day, kind, n FROM day_stats WHERE day >= ?", arrayOf(fromDay)).use { c ->
              while (c.moveToNext()) dayStats.put(JSONObject().put("day", c.getString(0)).put("kind", c.getString(1)).put("n", c.getLong(2)))
            }
          } catch (_: Exception) {}
          try {
            db.rawQuery("SELECT day, app, kind, n FROM app_stats WHERE day >= ?", arrayOf(fromDay)).use { c ->
              while (c.moveToNext()) appStats.put(JSONObject().put("day", c.getString(0)).put("app", c.getString(1)).put("kind", c.getString(2)).put("n", c.getLong(3)))
            }
          } catch (_: Exception) {}
          try {
            db.rawQuery("SELECT day, slot, app, kind, n FROM slot_stats WHERE day >= ?", arrayOf(fromDay)).use { c ->
              while (c.moveToNext()) slotStats.put(JSONObject().put("day", c.getString(0)).put("slot", c.getInt(1)).put("app", c.getString(2)).put("kind", c.getString(3)).put("n", c.getLong(4)))
            }
          } catch (_: Exception) {}
          try {
            db.rawQuery("SELECT day, slot, app, cpu, ram, n, peak, ior, iow FROM res WHERE day >= ?", arrayOf(fromDay)).use { c ->
              while (c.moveToNext()) {
                res.put(JSONObject().put("day", c.getString(0)).put("slot", c.getInt(1)).put("app", c.getString(2)).put("cpu", c.getLong(3)).put("ram", c.getLong(4)).put("n", c.getLong(5)).put("peak", c.getLong(6)).put("ior", c.getLong(7)).put("iow", c.getLong(8)))
              }
            }
          } catch (_: Exception) {}
          try {
            db.rawQuery("SELECT ts, kind, a, b FROM sysmon WHERE ts >= ?", arrayOf(sinceTs.toString())).use { c ->
              while (c.moveToNext()) sysmon.put(JSONObject().put("ts", c.getLong(0)).put("kind", c.getString(1)).put("a", c.getLong(2)).put("b", c.getLong(3)))
            }
          } catch (_: Exception) {}
          try {
            db.rawQuery("SELECT day, slot, app, ms FROM afk WHERE day >= ?", arrayOf(fromDay)).use { c ->
              while (c.moveToNext()) afk.put(JSONObject().put("day", c.getString(0)).put("slot", c.getInt(1)).put("app", c.getString(2)).put("ms", c.getLong(3)))
            }
          } catch (_: Exception) {}
          try {
            db.rawQuery("SELECT ts, kind, duration_ms, extra FROM sys_events WHERE ts >= ?", arrayOf(sinceTs.toString())).use { c ->
              while (c.moveToNext()) sysEvents.put(JSONObject().put("ts", c.getLong(0)).put("kind", c.getString(1)).put("duration_ms", c.getLong(2)).put("extra", c.getString(3) ?: ""))
            }
          } catch (_: Exception) {}
        } finally {
          db.close()
        }
      }
      return JSONObject()
        .put("device", JSONObject().put("id", deviceIdForContext(ctx)).put("name", deviceNameForContext(ctx)).put("platform", "android"))
        .put("usage", usage)
        .put("timeline", timeline)
        .put("apps", apps)
        .put("browser_usage", browser)
        .put("browser_timeline", browserTimeline)
        .put("day_stats", dayStats)
        .put("app_stats", appStats)
        .put("slot_stats", slotStats)
        .put("res", res)
        .put("sysmon", sysmon)
        .put("afk", afk)
        .put("sys_events", sysEvents)
        .toString()
    }
  }
}
