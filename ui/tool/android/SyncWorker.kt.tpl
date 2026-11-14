package __PACKAGE__

import android.app.AppOpsManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import android.os.Process
import androidx.core.app.NotificationCompat
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.Calendar

class SyncWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
  override fun doWork(): Result {
    try {
      Sync.run(applicationContext)
    } catch (ex: Exception) {
    }
    try {
      Sync.checkUpdate(applicationContext)
    } catch (ex: Exception) {
    }
    return Result.success()
  }
}

data class Ev(val pkg: String, val type: Int, val ms: Long)

data class Span(val app: String, val start: Long, val stop: Long)

object Sync {
  const val REPO = "arturwo1/trackwolium"

  fun dir(ctx: Context): File = File(ctx.filesDir, "Wolium")

  fun hasAccess(ctx: Context): Boolean {
    val ops = ctx.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
    val mode = ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), ctx.packageName)
    return mode == AppOpsManager.MODE_ALLOWED
  }

  fun events(ctx: Context, from: Long, to: Long): List<Map<String, Any>> {
    val mgr = ctx.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
    val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
    val launcher = ctx.packageManager.resolveActivity(home, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo?.packageName
    val out = ArrayList<Map<String, Any>>()
    val events = mgr.queryEvents(from, to)
    val e = UsageEvents.Event()
    while (events.hasNextEvent()) {
      events.getNextEvent(e)
      val t = e.eventType
      if (t != 1 && t != 2 && t != 16 && t != 26) continue
      val pkg = e.packageName ?: ""
      if (pkg == launcher || pkg == "com.android.systemui") {
        if (t == 1) out.add(mapOf("pkg" to pkg, "type" to 16, "time" to e.timeStamp))
        continue
      }
      out.add(mapOf("pkg" to pkg, "type" to t, "time" to e.timeStamp))
    }
    return out
  }

  fun label(ctx: Context, pkg: String): String {
    return try {
      ctx.packageManager.getApplicationLabel(ctx.packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (ex: Exception) {
      pkg
    }
  }

  fun icon(ctx: Context, pkg: String): ByteArray? {
    return try {
      val d = ctx.packageManager.getApplicationIcon(pkg)
      val size = 96
      val bmp = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
      d.setBounds(0, 0, size, size)
      d.draw(android.graphics.Canvas(bmp))
      val out = java.io.ByteArrayOutputStream()
      bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
      out.toByteArray()
    } catch (ex: Exception) {
      null
    }
  }

  fun build(events: List<Ev>, nowMs: Long): List<Span> {
    val sorted = events.sortedBy { it.ms }
    val out = ArrayList<Span>()
    var app: String? = null
    var started = 0L

    fun close(at: Long) {
      val a = app
      if (a != null && at - started >= 1000) out.add(Span(a, started / 1000, at / 1000))
      app = null
    }

    for (e in sorted) {
      when (e.type) {
        1 -> {
          if (app != e.pkg) {
            close(e.ms)
            app = e.pkg
            started = e.ms
          }
        }
        2 -> if (app == e.pkg) close(e.ms)
        16, 26 -> close(e.ms)
      }
    }
    close(nowMs)
    return out
  }

  private fun midnight(ms: Long): Calendar {
    val c = Calendar.getInstance()
    c.timeInMillis = ms
    c.set(Calendar.HOUR_OF_DAY, 0)
    c.set(Calendar.MINUTE, 0)
    c.set(Calendar.SECOND, 0)
    c.set(Calendar.MILLISECOND, 0)
    return c
  }

  private fun store(db: SQLiteDatabase, spans: List<Span>, firstDay: Calendar, lastDay: Calendar) {
    db.beginTransaction()
    try {
      for (s in spans) {
        db.execSQL("INSERT OR REPLACE INTO sessions(app, start, stop, state) VALUES(?, ?, ?, 0)", arrayOf<Any>(s.app, s.start, s.stop))
      }
      val day = firstDay.clone() as Calendar
      while (day.timeInMillis <= lastDay.timeInMillis) {
        val key = String.format("%04d-%02d-%02d", day.get(Calendar.YEAR), day.get(Calendar.MONTH) + 1, day.get(Calendar.DAY_OF_MONTH))
        val a = day.timeInMillis
        val next = day.clone() as Calendar
        next.add(Calendar.DAY_OF_MONTH, 1)
        val b = next.timeInMillis
        db.execSQL("DELETE FROM usage WHERE day = ?", arrayOf<Any>(key))
        db.execSQL("DELETE FROM timeline WHERE day = ?", arrayOf<Any>(key))
        val usage = HashMap<String, Long>()
        val timeline = HashMap<String, Long>()
        val cursor = db.rawQuery("SELECT app, start, stop FROM sessions WHERE stop > ${a / 1000} AND start < ${b / 1000}", null)
        while (cursor.moveToNext()) {
          val app = cursor.getString(0)
          var from = cursor.getLong(1) * 1000
          val to = minOf(cursor.getLong(2) * 1000, b)
          if (from < a) from = a
          if (to <= from) continue
          usage[app] = (usage[app] ?: 0L) + (to - from)
          var at = from
          while (at < to) {
            val slot = (at - a) / 300000
            val slotEnd = a + (slot + 1) * 300000
            val upTo = minOf(to, slotEnd)
            val k = "$slot\u0000$app"
            timeline[k] = (timeline[k] ?: 0L) + (upTo - at)
            at = upTo
          }
        }
        cursor.close()
        for ((app, ms) in usage) {
          db.execSQL("INSERT INTO usage(day, app, state, ms) VALUES(?, ?, 0, ?)", arrayOf<Any>(key, app, ms))
        }
        for ((k, ms) in timeline) {
          val i = k.indexOf('\u0000')
          db.execSQL("INSERT INTO timeline(day, slot, app, state, ms) VALUES(?, ?, ?, 0, ?)", arrayOf<Any>(key, k.substring(0, i).toLong(), k.substring(i + 1), ms))
        }
        day.add(Calendar.DAY_OF_MONTH, 1)
      }
      db.setTransactionSuccessful()
    } finally {
      db.endTransaction()
    }
  }

  private const val SCHEMA_USAGE = "CREATE TABLE IF NOT EXISTS usage(day TEXT NOT NULL, app TEXT NOT NULL, state INTEGER NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(day, app, state)) WITHOUT ROWID"
  private const val SCHEMA_TIMELINE = "CREATE TABLE IF NOT EXISTS timeline(day TEXT NOT NULL, slot INTEGER NOT NULL, app TEXT NOT NULL, state INTEGER NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(day, slot, app, state)) WITHOUT ROWID"
  private const val SCHEMA_SESSIONS = "CREATE TABLE IF NOT EXISTS sessions(app TEXT NOT NULL, start INTEGER NOT NULL, stop INTEGER NOT NULL, state INTEGER NOT NULL, PRIMARY KEY(app, start)) WITHOUT ROWID"
  private const val SCHEMA_APPS = "CREATE TABLE IF NOT EXISTS apps(app TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL DEFAULT '') WITHOUT ROWID"

  @Synchronized
  fun run(ctx: Context) {
    val dir = dir(ctx)
    if (!File(dir, "consent").exists() || File(dir, "paused").exists() || !hasAccess(ctx)) return
    val now = System.currentTimeMillis()
    val marker = File(dir, "sync")
    var since = now - 7L * 86400000L
    try {
      if (marker.exists()) since = marker.readText().trim().toLong() - 600000L
    } catch (ex: Exception) {
    }
    val firstDay = midnight(since)
    val lastDay = midnight(now)
    val queryFrom = firstDay.timeInMillis - 3600000L
    val events = events(ctx, queryFrom, now).map { Ev(it["pkg"] as String, it["type"] as Int, it["time"] as Long) }
    val spans = build(events, now)
    val db = SQLiteDatabase.openOrCreateDatabase(File(dir, "usage.db"), null)
    try {
      db.enableWriteAheadLogging()
      db.execSQL(SCHEMA_USAGE)
      db.execSQL(SCHEMA_TIMELINE)
      db.execSQL(SCHEMA_SESSIONS)
      db.execSQL(SCHEMA_APPS)
      store(db, spans, firstDay, lastDay)
      val known = HashSet<String>()
      val c = db.rawQuery("SELECT app, path FROM apps WHERE path != ''", null)
      while (c.moveToNext()) {
        if (File(c.getString(1)).exists()) known.add(c.getString(0))
      }
      c.close()
      for (app in spans.map { it.app }.toSet()) {
        if (known.contains(app)) continue
        var iconPath = ""
        val png = icon(ctx, app)
        if (png != null) {
          val icons = File(dir, "icons")
          icons.mkdirs()
          val f = File(icons, "$app.png")
          f.writeBytes(png)
          iconPath = f.absolutePath
        }
        db.execSQL("INSERT OR REPLACE INTO apps(app, name, path) VALUES(?, ?, ?)", arrayOf<Any>(app, label(ctx, app), iconPath))
      }
      db.rawQuery("PRAGMA wal_checkpoint(TRUNCATE)", null).close()
    } finally {
      db.close()
    }
    marker.writeText(now.toString())
  }

  private fun http(url: String): String {
    val c = URL(url).openConnection() as HttpURLConnection
    c.connectTimeout = 10000
    c.readTimeout = 15000
    c.setRequestProperty("User-Agent", "Wolium")
    c.setRequestProperty("Accept", "application/vnd.github+json")
    try {
      return c.inputStream.bufferedReader().readText()
    } finally {
      c.disconnect()
    }
  }

  fun compare(a: String, b: String): Int {
    val x = a.split('.').map { it.filter { ch -> ch.isDigit() }.toIntOrNull() ?: 0 }
    val y = b.split('.').map { it.filter { ch -> ch.isDigit() }.toIntOrNull() ?: 0 }
    for (i in 0 until maxOf(x.size, y.size)) {
      val p = x.getOrElse(i) { 0 }
      val q = y.getOrElse(i) { 0 }
      if (p != q) return if (p < q) -1 else 1
    }
    return 0
  }

  private fun text(ctx: Context, key: String): String {
    return try {
      val lang = try {
        File(dir(ctx), "lang").readText().trim()
      } catch (ex: Exception) {
        ""
      }
      val all = JSONObject(ctx.assets.open("strings.json").bufferedReader().readText())
      val pick = if (all.has(lang)) all.getJSONObject(lang) else all.getJSONObject("en")
      if (pick.has(key)) pick.getString(key) else all.getJSONObject("en").getString(key)
    } catch (ex: Exception) {
      key
    }
  }

  fun checkUpdate(ctx: Context) {
    val dir = dir(ctx)
    if (!File(dir, "consent").exists() || File(dir, "noupdates").exists()) return
    val current = ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: return
    val assets = JSONObject(http("https://api.github.com/repos/$REPO/releases/latest")).getJSONArray("assets")
    var versionUrl: String? = null
    var hasApk = false
    for (i in 0 until assets.length()) {
      val a = assets.getJSONObject(i)
      when (a.getString("name")) {
        "version.txt" -> versionUrl = a.getString("browser_download_url")
        "Wolium.apk" -> hasApk = true
      }
    }
    if (versionUrl == null || !hasApk) return
    val latest = http(versionUrl).trim()
    if (latest.isEmpty() || compare(current, latest) >= 0) return
    val prefs = ctx.getSharedPreferences("wolium", Context.MODE_PRIVATE)
    if (prefs.getString("notified", "") == latest) return
    val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= 26) {
      nm.createNotificationChannel(NotificationChannel("updates", text(ctx, "notifChannel"), NotificationManager.IMPORTANCE_DEFAULT))
    }
    val intent = Intent(ctx, MainActivity::class.java).putExtra("action", "update").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    val pending = PendingIntent.getActivity(ctx, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    val n = NotificationCompat.Builder(ctx, "updates")
      .setSmallIcon(ctx.applicationInfo.icon)
      .setContentTitle(text(ctx, "notifUpdateTitle"))
      .setContentText(String.format(text(ctx, "notifUpdateText"), latest))
      .setContentIntent(pending)
      .setAutoCancel(true)
      .build()
    nm.notify(1, n)
    prefs.edit().putString("notified", latest).apply()
  }
}

class CrashLog(private val ctx: Context, private val next: Thread.UncaughtExceptionHandler?) : Thread.UncaughtExceptionHandler {
  override fun uncaughtException(t: Thread, e: Throwable) {
    write(ctx, e)
    next?.uncaughtException(t, e)
  }

  companion object {
    fun write(ctx: Context, e: Throwable) {
      try {
        val text = android.util.Log.getStackTraceString(e)
        File(ctx.filesDir, "crash.txt").writeText(text)
        if (Build.VERSION.SDK_INT >= 29) {
          val values = android.content.ContentValues()
          values.put(android.provider.MediaStore.Downloads.DISPLAY_NAME, "wolium_crash.txt")
          values.put(android.provider.MediaStore.Downloads.MIME_TYPE, "text/plain")
          val uri = ctx.contentResolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
          if (uri != null) ctx.contentResolver.openOutputStream(uri)?.use { it.write(text.toByteArray()) }
        }
      } catch (x: Throwable) {
      }
    }
  }
}
