package __PACKAGE__

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class ApiService : Service() {
  @Volatile private var running = false
  private var server: ServerSocket? = null
  private var started = 0L

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    if (running) return START_STICKY
    if (!File(Sync.dir(applicationContext), "localapi").exists() || !File(Sync.dir(applicationContext), "consent").exists()) {
      stopSelf()
      return START_NOT_STICKY
    }
    startForegroundCompat()
    running = true
    started = System.currentTimeMillis()
    Thread { serve() }.start()
    Thread { refresh() }.start()
    return START_STICKY
  }

  override fun onDestroy() {
    running = false
    try {
      server?.close()
    } catch (ex: Exception) {
    }
    super.onDestroy()
  }

  private fun startForegroundCompat() {
    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= 26) {
      nm.createNotificationChannel(NotificationChannel("api", Sync.text(this, "apiNotifChannel"), NotificationManager.IMPORTANCE_LOW))
    }
    val open = PendingIntent.getActivity(this, 1, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    val n: Notification = NotificationCompat.Builder(this, "api")
      .setSmallIcon(applicationInfo.icon)
      .setContentTitle(Sync.text(this, "apiNotifText"))
      .setContentIntent(open)
      .setOngoing(true)
      .setOnlyAlertOnce(true)
      .setPriority(NotificationCompat.PRIORITY_LOW)
      .setCategory(NotificationCompat.CATEGORY_SERVICE)
      .build()
    if (Build.VERSION.SDK_INT >= 34) startForeground(7, n, 1073741824) else startForeground(7, n)
  }

  private fun refresh() {
    while (running) {
      try {
        Sync.run(applicationContext)
      } catch (ex: Exception) {
      }
      var waited = 0
      while (running && waited < 60000) {
        Thread.sleep(500)
        waited += 500
      }
    }
  }

  private fun serve() {
    try {
      val s = ServerSocket(PORT, 8, InetAddress.getByName("127.0.0.1"))
      server = s
      while (running) {
        val c = s.accept()
        Thread { handle(c) }.start()
      }
    } catch (ex: Exception) {
    }
  }

  private fun handle(c: Socket) {
    try {
      c.soTimeout = 1500
      val input = c.getInputStream()
      val buf = ByteArray(4096)
      val raw = java.io.ByteArrayOutputStream()
      var hdrEnd = -1
      while (raw.size() < 24576) {
        val n = input.read(buf)
        if (n <= 0) break
        raw.write(buf, 0, n)
        val s = String(raw.toByteArray(), Charsets.ISO_8859_1)
        hdrEnd = s.indexOf("\r\n\r\n")
        if (hdrEnd >= 0) break
      }
      if (hdrEnd < 0) {
        c.getOutputStream().write(http(400, "{\"error\":\"bad request\"}").toByteArray(Charsets.UTF_8))
        return
      }
      var allBytes = raw.toByteArray()
      val headerText = String(allBytes, 0, hdrEnd, Charsets.ISO_8859_1)
      val lines = headerText.split("\r\n")
      val parts = lines.firstOrNull()?.split(" ") ?: emptyList()
      var host = ""
      var contentLen = 0
      for (l in lines.drop(1)) {
        val i = l.indexOf(':')
        if (i <= 0) continue
        val k = l.substring(0, i).trim().lowercase(Locale.ROOT)
        val v = l.substring(i + 1).trim()
        if (k == "host") host = v.lowercase(Locale.ROOT)
        else if (k == "content-length") contentLen = (v.toIntOrNull() ?: 0).coerceIn(0, 16384)
      }
      val bodyStart = hdrEnd + 4
      while (allBytes.size < bodyStart + contentLen) {
        val n = input.read(buf)
        if (n <= 0) break
        raw.write(buf, 0, n)
        allBytes = raw.toByteArray()
      }
      val reqBody = if (allBytes.size > bodyStart && contentLen > 0) {
        String(allBytes, bodyStart, minOf(contentLen, allBytes.size - bodyStart), Charsets.UTF_8)
      } else ""
      val method = parts.firstOrNull() ?: ""
      val response = when {
        parts.size < 3 || (method != "GET" && method != "POST") || !parts[2].startsWith("HTTP/1.") || (host != "127.0.0.1:$PORT" && host != "localhost:$PORT") ->
          http(400, "{\"error\":\"bad request\"}")
        else -> route(method, parts[1], reqBody)
      }
      c.getOutputStream().write(response.toByteArray(Charsets.UTF_8))
      c.getOutputStream().flush()
    } catch (ex: Exception) {
    } finally {
      try {
        c.close()
      } catch (ex: Exception) {
      }
    }
  }

  private fun queryInt(query: String, key: String, fallback: Int, lo: Int, hi: Int): Int {
    for (part in query.split("&")) {
      val i = part.indexOf('=')
      if (i > 0 && part.substring(0, i) == key) {
        val v = part.substring(i + 1)
        if (v.isNotEmpty() && v.length <= 9 && v.all { it in '0'..'9' }) return maxOf(lo, minOf(hi, v.toInt()))
      }
    }
    return fallback
  }

  private fun queryText(query: String, key: String): String {
    for (part in query.split("&")) {
      val i = part.indexOf('=')
      if (i > 0 && part.substring(0, i) == key) return part.substring(i + 1)
    }
    return ""
  }

  private fun withDb(block: (SQLiteDatabase) -> Unit) {
    try {
      val file = File(Sync.dir(applicationContext), "usage.db")
      if (file.exists()) {
        val db = SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY)
        try {
          block(db)
        } finally {
          db.close()
        }
      }
    } catch (ex: Exception) {
    }
  }

  private fun totalsJson(ms: LongArray): String =
    "\"focused_ms\":${ms[0]},\"open_ms\":${ms[1]},\"minimized_ms\":${ms[2]},\"background_ms\":${ms[3]},\"total_ms\":${ms.sum()}"

  private fun topJson(apps: Map<String, LongArray>, names: Map<String, String>, metric: String, limit: Int): String {
    fun key(t: LongArray): Long = when (metric) {
      "open" -> t[1]
      "minimized" -> t[2]
      "background" -> t[3]
      "all" -> t.sum()
      else -> t[0]
    }
    val list = apps.entries.sortedWith(compareByDescending<Map.Entry<String, LongArray>> { key(it.value) }.thenBy { it.key })
    val o = StringBuilder("[")
    var n = 0
    for (e in list) {
      if (n >= limit || key(e.value) <= 0) break
      if (n++ > 0) o.append(',')
      val name = names[e.key]?.takeIf { it.isNotEmpty() } ?: e.key
      o.append("{\"app\":\"").append(esc(e.key)).append("\",\"name\":\"").append(esc(name)).append("\",").append(totalsJson(e.value)).append('}')
    }
    return o.append(']').toString()
  }

  private fun route(method: String, target: String, reqBody: String): String {
    val qm = target.indexOf('?')
    var path = if (qm < 0) target else target.substring(0, qm)
    val query = if (qm < 0) "" else target.substring(qm + 1)
    if (path.length > 1 && path.endsWith("/")) path = path.dropLast(1)
    val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.US)
    val now = System.currentTimeMillis()
    if (method == "POST") {
      if (path != "/v1/browser") return http(404, "{\"error\":\"not found\"}");
      return try {
        val obj = org.json.JSONObject(reqBody)
        val browser = obj.optString("browser", "").trim().lowercase(Locale.ROOT).take(64)
        val domain = obj.optString("domain", "").trim().lowercase(Locale.ROOT).take(192)
        val title = obj.optString("title", "").replace(Regex("[\\u0000-\\u001F]"), " ").replace(Regex("\\s+"), " ").trim().take(180)
        val rawUrl = obj.optString("url", "").trim().take(512)
        val urlOk = (rawUrl.startsWith("http://", ignoreCase = true) || rawUrl.startsWith("https://", ignoreCase = true)) && rawUrl.none { it.code < 0x20 || it == ' ' || it == '<' || it == '>' }
        val url = if (urlOk) rawUrl else ""
        val ms = obj.optLong("ms", 0L)
        if (browser.isEmpty() || domain.isEmpty() || ms <= 0 || ms > 3600000L) {
          http(400, "{\"error\":\"bad payload\"}")
        } else {
          val day = fmt.format(Date(now))
          val cal = java.util.Calendar.getInstance().apply { timeInMillis = now }
          val slot = ((cal.get(java.util.Calendar.HOUR_OF_DAY) * 3600 + cal.get(java.util.Calendar.MINUTE) * 60 + cal.get(java.util.Calendar.SECOND)) / 300).coerceIn(0, 287)
          val file = File(Sync.dir(applicationContext), "usage.db")
          file.parentFile?.mkdirs()
          val db = SQLiteDatabase.openOrCreateDatabase(file, null)
          try {
            db.enableWriteAheadLogging()
            db.execSQL("CREATE TABLE IF NOT EXISTS browser_usage(day TEXT NOT NULL, browser TEXT NOT NULL, domain TEXT NOT NULL, ms INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '', url TEXT NOT NULL DEFAULT '', PRIMARY KEY(day, browser, domain)) WITHOUT ROWID")
            db.execSQL("CREATE TABLE IF NOT EXISTS browser_timeline(day TEXT NOT NULL, slot INTEGER NOT NULL, browser TEXT NOT NULL, domain TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', ms INTEGER NOT NULL, PRIMARY KEY(day, slot, browser, domain)) WITHOUT ROWID")
            try { db.execSQL("ALTER TABLE browser_usage ADD COLUMN title TEXT NOT NULL DEFAULT ''") } catch (_: Exception) {}
            try { db.execSQL("ALTER TABLE browser_usage ADD COLUMN url TEXT NOT NULL DEFAULT ''") } catch (_: Exception) {}
            db.beginTransaction()
            try {
              db.execSQL(
                "INSERT INTO browser_usage(day, browser, domain, ms, title, url) VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(day, browser, domain) DO UPDATE SET ms = ms + excluded.ms, title = CASE WHEN excluded.title != '' THEN excluded.title ELSE browser_usage.title END, url = CASE WHEN excluded.url != '' THEN excluded.url ELSE browser_usage.url END",
                arrayOf<Any>(day, browser, domain, ms, title, url)
              )
              db.execSQL(
                "INSERT INTO browser_timeline(day, slot, browser, domain, title, ms) VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(day, slot, browser, domain) DO UPDATE SET ms = ms + excluded.ms, title = CASE WHEN excluded.title != '' THEN excluded.title ELSE browser_timeline.title END",
                arrayOf<Any>(day, slot, browser, domain, title, ms)
              )
              db.setTransactionSuccessful()
            } finally {
              db.endTransaction()
            }
          } finally {
            db.close()
          }
          http(200, "{\"ok\":true}")
        }
      } catch (ex: Exception) {
        http(400, "{\"error\":\"bad json\"}")
      }
    }
    if (path == "/widget") {
      val html = try {
        assets.open("widget.html").use { String(it.readBytes(), Charsets.UTF_8) }
      } catch (ex: Exception) {
        return http(404, "{\"error\":\"not found\"}")
      }
      return http(200, html, "text/html; charset=utf-8")
    }
    if (path == "/v1/current") return http(200, current())
    if (path == "/v1/browser/top") {
      val days = queryInt(query, "days", 1, 1, 90)
      val limit = queryInt(query, "limit", 10, 1, 100)
      val to = fmt.format(Date(now))
      val from = fmt.format(Date(now - (days - 1) * 86400000L))
      val o = StringBuilder("{\"from\":\"$from\",\"to\":\"$to\",\"days\":$days,\"domains\":[")
      var first = true
      withDb { db ->
        try {
          db.rawQuery(
            "SELECT browser, domain, SUM(ms) AS total, MAX(title) AS title, MAX(url) AS url FROM browser_usage WHERE day >= ? AND day <= ? GROUP BY browser, domain ORDER BY total DESC LIMIT ?",
            arrayOf(from, to, limit.toString())
          ).use { c ->
            while (c.moveToNext()) {
              if (!first) o.append(',')
              first = false
              o.append("{\"browser\":\"").append(esc(c.getString(0))).append("\",\"domain\":\"").append(esc(c.getString(1)))
                .append("\",\"title\":\"").append(esc(c.getString(3) ?: "")).append("\",\"url\":\"").append(esc(c.getString(4) ?: ""))
                .append("\",\"ms\":").append(c.getLong(2)).append('}')
            }
          }
        } catch (ex: Exception) {
          try {
            db.rawQuery(
              "SELECT browser, domain, SUM(ms) AS total FROM browser_usage WHERE day >= ? AND day <= ? GROUP BY browser, domain ORDER BY total DESC LIMIT ?",
              arrayOf(from, to, limit.toString())
            ).use { c ->
              while (c.moveToNext()) {
                if (!first) o.append(',')
                first = false
                o.append("{\"browser\":\"").append(esc(c.getString(0))).append("\",\"domain\":\"").append(esc(c.getString(1)))
                  .append("\",\"title\":\"\",\"url\":\"\",\"ms\":").append(c.getLong(2)).append('}')
              }
            }
          } catch (_: Exception) {
          }
        }
      }
      o.append("]}")
      return http(200, o.toString())
    }
    if (path == "/v1/summary" || path == "/v1/stats" || path == "/v1/apps/top") {
      val top = path == "/v1/apps/top"
      val days = queryInt(query, "days", if (top) 1 else 7, 1, 90)
      val to = fmt.format(Date(now))
      val from = fmt.format(Date(now - (days - 1) * 86400000L))
      val metric = queryText(query, "metric").let { if (it == "open" || it == "minimized" || it == "background" || it == "all") it else "focused" }
      val apps = LinkedHashMap<String, LongArray>()
      val byDay = java.util.TreeMap<String, LongArray>()
      val names = HashMap<String, String>()
      val all = LongArray(4)
      withDb { db ->
        db.rawQuery("SELECT day, app, state, ms FROM usage WHERE day >= ? AND day <= ?", arrayOf(from, to)).use { c ->
          while (c.moveToNext()) {
            val st = c.getInt(2)
            if (st !in 0..3) continue
            val ms = c.getLong(3)
            apps.getOrPut(c.getString(1)) { LongArray(4) }[st] += ms
            byDay.getOrPut(c.getString(0)) { LongArray(4) }[st] += ms
            all[st] += ms
          }
        }
        try {
          db.rawQuery("SELECT app, name FROM apps", null).use { c ->
            while (c.moveToNext()) names[c.getString(0)] = c.getString(1)
          }
        } catch (ex: Exception) {
        }
      }
      if (top) {
        val limit = queryInt(query, "limit", 5, 1, 50)
        return http(200, "{\"from\":\"$from\",\"to\":\"$to\",\"days\":$days,\"metric\":\"$metric\",\"apps\":${topJson(apps, names, metric, limit)}}")
      }
      val o = StringBuilder("{\"from\":\"$from\",\"to\":\"$to\",\"days\":$days,\"apps_count\":${apps.size},")
      o.append(totalsJson(all)).append(",\"by_day\":[")
      var first = true
      for ((d, ms) in byDay) {
        if (!first) o.append(',')
        first = false
        o.append("{\"day\":\"").append(d).append("\",").append(totalsJson(ms)).append('}')
      }
      o.append("],\"top\":").append(topJson(apps, names, metric, 5)).append('}')
      return http(200, o.toString())
    }
    if (path == "/v1/sessions") {
      val hours = queryInt(query, "hours", 24, 1, 24 * 90)
      val limit = queryInt(query, "limit", 100, 1, 500)
      val states = arrayOf("focused", "open", "minimized", "background")
      val o = StringBuilder("{\"hours\":$hours,\"sessions\":[")
      var first = true
      withDb { db ->
        val to = now / 1000
        val sql = "SELECT s.app, COALESCE(a.name, ''), s.state, s.start, s.stop FROM sessions s LEFT JOIN apps a ON a.app = s.app WHERE s.start >= ${to - hours * 3600L} AND s.start <= $to ORDER BY s.start DESC LIMIT $limit"
        db.rawQuery(sql, null).use { c ->
          while (c.moveToNext()) {
            if (!first) o.append(',')
            first = false
            val app = c.getString(0)
            val name = c.getString(1).ifEmpty { app }
            o.append("{\"app\":\"").append(esc(app)).append("\",\"name\":\"").append(esc(name)).append("\",\"state\":\"")
              .append(states[c.getInt(2).coerceIn(0, 3)]).append("\",\"start\":").append(c.getLong(3)).append(",\"stop\":").append(c.getLong(4)).append('}')
          }
        }
      }
      o.append("]}")
      return http(200, o.toString())
    }
    return http(404, "{\"error\":\"not found\"}")
  }

  private fun http(status: Int, body: String, type: String = "application/json; charset=utf-8"): String {
    val text = when (status) {
      200 -> "OK"
      404 -> "Not Found"
      else -> "Bad Request"
    }
    val bytes = body.toByteArray(Charsets.UTF_8).size
    return "HTTP/1.1 $status $text\r\nContent-Type: $type\r\nContent-Length: $bytes\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n$body"
  }

  private fun esc(s: String): String {
    val o = StringBuilder()
    for (ch in s) {
      if (ch == '"' || ch == '\\') {
        o.append('\\').append(ch)
      } else if (ch.code < 0x20) {
        o.append(' ')
      } else {
        o.append(ch)
      }
    }
    return o.toString()
  }

  private fun foreground(): String? {
    return try {
      val now = System.currentTimeMillis()
      var current: String? = null
      for (e in Sync.events(applicationContext, now - 900000L, now)) {
        val type = e["type"] as Int
        val pkg = e["pkg"] as String
        if (type == 1) {
          current = pkg
        } else if (type == 2 && current == pkg) {
          current = null
        } else if (type == 16 || type == 26) {
          current = null
        }
      }
      current
    } catch (ex: Exception) {
      null
    }
  }

  private fun current(): String {
    val day = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
    val focus = foreground()
    val totals = LinkedHashMap<String, LongArray>()
    try {
      val file = File(Sync.dir(applicationContext), "usage.db")
      if (file.exists()) {
        val db = SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY)
        db.rawQuery("SELECT app, state, ms FROM usage WHERE day = ?", arrayOf(day)).use { c ->
          while (c.moveToNext()) {
            val st = c.getInt(1)
            if (st in 0..3) totals.getOrPut(c.getString(0)) { LongArray(4) }[st] += c.getLong(2)
          }
        }
        db.close()
      }
    } catch (ex: Exception) {
    }
    val o = StringBuilder()
    o.append("{\"uptime_ms\":").append(System.currentTimeMillis() - started).append(",\"apps\":[")
    var first = true
    for ((app, ms) in totals) {
      if (!first) o.append(',')
      first = false
      val on = app == focus
      o.append("{\"app\":\"").append(esc(app)).append("\",\"running\":").append(on).append(",\"state\":\"").append(if (on) "focused" else "background")
        .append("\",\"focused_ms\":").append(ms[0]).append(",\"open_ms\":").append(ms[1]).append(",\"minimized_ms\":").append(ms[2])
        .append(",\"background_ms\":").append(ms[3]).append('}')
    }
    o.append("]}")
    return o.toString()
  }

  companion object {
    const val PORT = 9095

    fun apply(ctx: Context, on: Boolean) {
      val intent = Intent(ctx, ApiService::class.java)
      if (on) {
        if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(intent) else ctx.startService(intent)
      } else {
        ctx.stopService(intent)
      }
    }
  }
}

class BootReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    try {
      if (File(Sync.dir(context), "localapi").exists() && File(Sync.dir(context), "consent").exists()) ApiService.apply(context, true)
    } catch (ex: Exception) {
    }
  }
}
