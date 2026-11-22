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
    return Result.success()
  }
}

class UpdateWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
  override fun doWork(): Result {
    return try {
      Sync.checkUpdate(applicationContext)
      Result.success()
    } catch (ex: Exception) {
      Result.retry()
    }
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
      val pkg = e.packageName ?: ""
      if (t == 18) {
        out.add(mapOf("pkg" to pkg, "type" to 18, "time" to e.timeStamp))
        continue
      }
      if (t == 12) {
        if (pkg.isNotEmpty() && pkg != launcher && pkg != "com.android.systemui") {
          out.add(mapOf("pkg" to pkg, "type" to 12, "time" to e.timeStamp))
        }
        continue
      }
      if (t != 1 && t != 2 && t != 16 && t != 17 && t != 26) continue
      if (pkg == launcher || pkg == "com.android.systemui") {
        if (t == 1) out.add(mapOf("pkg" to pkg, "type" to 16, "time" to e.timeStamp))
        continue
      }
      out.add(mapOf("pkg" to pkg, "type" to t, "time" to e.timeStamp))
    }
    return out
  }

  fun deviceName(ctx: Context): String {
    fun setting(name: String): String {
      var v: String? = null
      try {
        v = android.provider.Settings.Global.getString(ctx.contentResolver, name)
      } catch (_: Exception) {}
      if (v.isNullOrBlank()) {
        try {
          v = android.provider.Settings.Secure.getString(ctx.contentResolver, name)
        } catch (_: Exception) {}
      }
      return (v ?: "").trim()
    }
    var name = setting("device_name")
    if (name.isEmpty()) name = setting("bluetooth_name")
    if (name.isEmpty()) {
      val maker = Build.MANUFACTURER ?: ""
      val model = Build.MODEL ?: ""
      val brand = if (maker.isEmpty()) "" else maker.substring(0, 1).uppercase() + maker.substring(1)
      name = if (model.lowercase().startsWith(maker.lowercase())) model else "$brand $model".trim()
    }
    return name
  }

  fun label(ctx: Context, pkg: String): String {
    return try {
      ctx.packageManager.getApplicationLabel(ctx.packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (ex: Exception) {
      pkg
    }
  }

  private val gamePrefixes = listOf(
    "com.miniclip.", "com.supercell.", "com.rovio.", "com.kiloo.", "com.halfbrick.",
    "com.king.", "com.mojang.", "com.innersloth.", "com.ea.game.", "com.gameloft.",
    "com.playrix.", "com.zynga.", "com.nianticlabs.", "jp.co.ponos.", "com.prineside.",
    "org.lichess.", "com.blackmoondev.", "com.asobimo.", "com.mihoyo.", "com.nexon."
  )
  private val gameTokens = listOf(
    "eightballpool", "minecraft", "brawlstars", "clashroyale", "clashofclans",
    "amongus", "subwaysurf", "infinitode", "magicrampage", "smashingfour", "battlecats", "lichess"
  )

  fun systemCategory(ctx: Context, pkg: String): Int {
    val lp = pkg.lowercase(java.util.Locale.ROOT)
    if (gamePrefixes.any { lp.startsWith(it) } || gameTokens.any { lp.contains(it) }) return 0
    return try {
      val info = ctx.packageManager.getApplicationInfo(pkg, 0)
      if ((info.flags and android.content.pm.ApplicationInfo.FLAG_IS_GAME) != 0) 0 else if (Build.VERSION.SDK_INT >= 26) info.category else -1
    } catch (ex: Exception) {
      -1
    }
  }

  fun icon(ctx: Context, pkg: String): ByteArray? {
    return try {
      val d = (ctx.packageManager.getApplicationIcon(pkg).constantState?.newDrawable() ?: ctx.packageManager.getApplicationIcon(pkg)).mutate()
      val size = 96
      val bmp = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
      val canvas = android.graphics.Canvas(bmp)
      d.setBounds(0, 0, size, size)
      d.draw(canvas)
      val out = java.io.ByteArrayOutputStream()
      bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
      out.toByteArray()
    } catch (ex: Exception) {
      null
    }
  }

  fun ensureIcon(ctx: Context, dir: File, pkg: String): String {
    val icons = File(dir, "icons")
    val target = File(icons, "$pkg.png")
    if (target.exists() && target.length() > 0) return target.absolutePath
    val png = icon(ctx, pkg) ?: return ""
    icons.mkdirs()
    target.writeBytes(png)
    return target.absolutePath
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
        16, 17, 26 -> close(e.ms)
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

  private fun store(db: SQLiteDatabase, spans: List<Span>, events: List<Ev>, firstDay: Calendar, lastDay: Calendar) {
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
        db.execSQL("DELETE FROM app_stats WHERE day = ? AND kind = 'opens'", arrayOf<Any>(key))
        val usage = HashMap<String, Long>()
        val timeline = HashMap<String, Long>()
        val opens = HashMap<String, Long>()
        val aSec = a / 1000
        val bSec = b / 1000
        val cursor = db.rawQuery("SELECT app, start, stop FROM sessions WHERE stop > $aSec AND start < $bSec", null)
        while (cursor.moveToNext()) {
          val app = cursor.getString(0)
          val rawStart = cursor.getLong(1)
          var from = rawStart * 1000
          val to = minOf(cursor.getLong(2) * 1000, b)
          if (rawStart in aSec until bSec) {
            opens[app] = (opens[app] ?: 0L) + 1L
          }
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
        for ((app, n) in opens) {
          db.execSQL("INSERT INTO app_stats(day, app, kind, n) VALUES(?, ?, 'opens', ?)", arrayOf<Any>(key, app, n))
        }
        var dayEvents = 0
        var unlocks = 0L
        val notifs = HashMap<String, Long>()
        for (ev in events) {
          if (ev.ms < a || ev.ms >= b) continue
          dayEvents++
          if (ev.type == 18) unlocks++
          else if (ev.type == 12 && ev.pkg.isNotEmpty()) notifs[ev.pkg] = (notifs[ev.pkg] ?: 0L) + 1L
        }
        if (dayEvents > 0 || unlocks > 0 || notifs.isNotEmpty()) {
          db.execSQL("DELETE FROM day_stats WHERE day = ? AND kind = 'unlocks'", arrayOf<Any>(key))
          db.execSQL("DELETE FROM app_stats WHERE day = ? AND kind = 'notifs'", arrayOf<Any>(key))
          if (unlocks > 0) db.execSQL("INSERT INTO day_stats(day, kind, n) VALUES(?, 'unlocks', ?)", arrayOf<Any>(key, unlocks))
          for ((app, n) in notifs) {
            db.execSQL("INSERT INTO app_stats(day, app, kind, n) VALUES(?, ?, 'notifs', ?)", arrayOf<Any>(key, app, n))
          }
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
  private const val SCHEMA_APPCAT = "CREATE TABLE IF NOT EXISTS appcat(app TEXT PRIMARY KEY, cat INTEGER NOT NULL) WITHOUT ROWID"
  private const val SCHEMA_APPS = "CREATE TABLE IF NOT EXISTS apps(app TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL DEFAULT '') WITHOUT ROWID"
  private const val SCHEMA_DAY_STATS = "CREATE TABLE IF NOT EXISTS day_stats(day TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(day, kind)) WITHOUT ROWID"
  private const val SCHEMA_APP_STATS = "CREATE TABLE IF NOT EXISTS app_stats(day TEXT NOT NULL, app TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(day, app, kind)) WITHOUT ROWID"

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
      db.execSQL(SCHEMA_APPCAT)
      db.execSQL(SCHEMA_DAY_STATS)
      db.execSQL(SCHEMA_APP_STATS)
      store(db, spans, events, firstDay, lastDay)
      val known = HashSet<String>()
      val c = db.rawQuery("SELECT app, path FROM apps WHERE path != ''", null)
      while (c.moveToNext()) {
        if (File(c.getString(1)).exists()) known.add(c.getString(0))
      }
      c.close()
      for (app in spans.map { it.app }.toSet()) {
        if (known.contains(app)) continue
        val iconPath = ensureIcon(ctx, dir, app)
        db.execSQL("INSERT OR REPLACE INTO apps(app, name, path) VALUES(?, ?, ?)", arrayOf<Any>(app, label(ctx, app), iconPath))
      }
      db.rawQuery("PRAGMA wal_checkpoint(TRUNCATE)", null).close()
    } finally {
      db.close()
    }
    marker.writeText(now.toString())
    try {
      categorize(ctx)
    } catch (ex: Exception) {
    }
    try {
      checkLimits(ctx)
    } catch (ex: Exception) {
    }
  }

  fun checkLimits(ctx: Context) {
    val dir = dir(ctx)
    val limits = File(dir, "limits")
    val file = File(dir, "usage.db")
    if (!limits.exists() || !file.exists() || File(dir, "paused").exists()) return
    val now = Calendar.getInstance()
    val day = String.format("%04d-%02d-%02d", now.get(Calendar.YEAR), now.get(Calendar.MONTH) + 1, now.get(Calendar.DAY_OF_MONTH))
    val firedFile = File(dir, "limitfired")
    val fired = HashSet<String>()
    if (firedFile.exists()) {
      val lines = firedFile.readLines()
      if (lines.isNotEmpty() && lines[0] == day) fired.addAll(lines.drop(1))
    }
    val db = SQLiteDatabase.openDatabase(file.absolutePath, null, SQLiteDatabase.OPEN_READONLY)
    val hits = ArrayList<List<String>>()
    try {
      for (line in limits.readLines()) {
        val p = line.split('\t')
        if (p.size < 3) continue
        val secs = p[0].toLongOrNull() ?: continue
        if (secs < 60) continue
        val key = "$secs|${p[1]}"
        if (fired.contains(key)) continue
        val apps = p[2].split('\u001f').filter { it.isNotEmpty() }
        if (apps.isEmpty()) continue
        val marks = apps.joinToString(",") { "?" }
        val args = arrayOf(day) + apps.toTypedArray()
        val c = db.rawQuery("SELECT COALESCE(SUM(ms), 0) FROM usage WHERE day = ? AND state = 0 AND app IN ($marks)", args)
        var spent = 0L
        if (c.moveToFirst()) spent = c.getLong(0)
        c.close()
        if (spent >= secs * 1000) {
          fired.add(key)
          hits.add(listOf(if (p.size > 3 && p[3].isNotEmpty()) p[3] else p[1], if (p.size > 4 && p[4].isNotEmpty()) p[4] else p[1]))
        }
      }
    } finally {
      db.close()
    }
    if (hits.isEmpty()) return
    firedFile.writeText(day + "\n" + fired.joinToString("\n") + "\n")
    val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= 26) {
      nm.createNotificationChannel(NotificationChannel("limits", text(ctx, "limitChannel"), NotificationManager.IMPORTANCE_DEFAULT))
    }
    if (!nm.areNotificationsEnabled()) return
    var id = 100
    for (h in hits) {
      val open = PendingIntent.getActivity(ctx, id, Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
      val n = NotificationCompat.Builder(ctx, "limits")
        .setSmallIcon(ctx.applicationInfo.icon)
        .setContentTitle(h[0])
        .setContentText(h[1])
        .setContentIntent(open)
        .setAutoCancel(true)
        .build()
      nm.notify(id++, n)
    }
  }

  fun categorize(ctx: Context) {
    val d = dir(ctx)
    val file = File(d, "usage.db")
    if (!file.exists()) return
    val db = SQLiteDatabase.openOrCreateDatabase(file, null)
    try {
      db.enableWriteAheadLogging()
      db.execSQL(SCHEMA_APPS)
      db.execSQL(SCHEMA_APPCAT)
      val known = HashSet<String>()
      val haveIcon = HashSet<String>()
      val kc = db.rawQuery("SELECT app, path FROM apps", null)
      while (kc.moveToNext()) {
        val pkg = kc.getString(0)
        val p = kc.getString(1)
        known.add(pkg)
        if (p.isNotEmpty() && File(p).exists()) haveIcon.add(pkg)
      }
      kc.close()
      val launcher = android.content.Intent(android.content.Intent.ACTION_MAIN).addCategory(android.content.Intent.CATEGORY_LAUNCHER)
      for (ri in ctx.packageManager.queryIntentActivities(launcher, 0)) {
        val pkg = ri.activityInfo.packageName
        if (pkg == ctx.packageName) continue
        val iconPath = if (haveIcon.contains(pkg)) "" else ensureIcon(ctx, d, pkg)
        if (!known.contains(pkg)) {
          db.execSQL("INSERT OR IGNORE INTO apps(app, name, path) VALUES(?, ?, ?)", arrayOf<Any>(pkg, ri.loadLabel(ctx.packageManager).toString(), iconPath))
          known.add(pkg)
          if (iconPath.isNotEmpty()) haveIcon.add(pkg)
        } else if (iconPath.isNotEmpty()) {
          db.execSQL("UPDATE apps SET path = ? WHERE app = ? AND path = ''", arrayOf<Any>(iconPath, pkg))
          haveIcon.add(pkg)
        }
      }
      for (pkg in known) {
        if (pkg == ctx.packageName || haveIcon.contains(pkg)) continue
        val iconPath = ensureIcon(ctx, d, pkg)
        if (iconPath.isNotEmpty()) {
          db.execSQL("UPDATE apps SET path = ? WHERE app = ?", arrayOf<Any>(iconPath, pkg))
          haveIcon.add(pkg)
        }
      }
      val vc = db.rawQuery("SELECT cat FROM appcat WHERE app = '__v'", null)
      val version = if (vc.moveToFirst()) vc.getInt(0) else 0
      vc.close()
      if (version != 4) db.execSQL("DELETE FROM appcat")
      val have = HashSet<String>()
      val hc = db.rawQuery("SELECT app FROM appcat", null)
      while (hc.moveToNext()) have.add(hc.getString(0))
      hc.close()
      db.beginTransaction()
      try {
        for (app in known) {
          if (!have.contains(app)) db.execSQL("INSERT OR REPLACE INTO appcat(app, cat) VALUES(?, ?)", arrayOf<Any>(app, systemCategory(ctx, app)))
        }
        db.execSQL("INSERT OR REPLACE INTO appcat(app, cat) VALUES('__v', 4)")
        db.setTransactionSuccessful()
      } finally {
        db.endTransaction()
      }
    } finally {
      db.close()
    }
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

  fun text(ctx: Context, key: String): String {
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

  fun updateDir(ctx: Context): File = File(ctx.cacheDir, "update")

  fun readyApk(ctx: Context): File? {
    val prefs = ctx.getSharedPreferences("wolium", Context.MODE_PRIVATE)
    val version = prefs.getString("ready_version", "") ?: ""
    val file = File(updateDir(ctx), "Wolium-$version.apk")
    val current = ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: ""
    if (version.isEmpty() || !file.exists() || compare(current, version) >= 0) {
      cleanUpdates(ctx)
      return null
    }
    return file
  }

  fun cleanUpdates(ctx: Context) {
    try {
      updateDir(ctx).listFiles()?.forEach { it.delete() }
      ctx.getSharedPreferences("wolium", Context.MODE_PRIVATE).edit().remove("ready_version").apply()
    } catch (ex: Exception) {
    }
  }

  private fun download(url: String, target: File): Boolean {
    target.parentFile?.mkdirs()
    val part = File(target.path + ".part")
    val c = URL(url).openConnection() as HttpURLConnection
    c.connectTimeout = 15000
    c.readTimeout = 30000
    c.setRequestProperty("User-Agent", "Wolium")
    try {
      if (c.responseCode != 200) return false
      val total = c.contentLengthLong
      var got = 0L
      c.inputStream.use { input ->
        part.outputStream().use { out ->
          val buf = ByteArray(65536)
          while (true) {
            val n = input.read(buf)
            if (n <= 0) break
            out.write(buf, 0, n)
            got += n
          }
        }
      }
      if ((total > 0 && got != total) || got < 1024 * 1024) {
        part.delete()
        return false
      }
      if (target.exists()) target.delete()
      return part.renameTo(target)
    } finally {
      c.disconnect()
      if (part.exists() && !target.exists()) part.delete()
    }
  }

  fun isStore(ctx: Context): Boolean = try {
    ctx.assets.list("")?.contains("store") == true
  } catch (ex: Exception) {
    false
  }

  fun checkUpdate(ctx: Context) {
    if (isStore(ctx)) return
    val dir = dir(ctx)
    if (!File(dir, "consent").exists() || File(dir, "noupdates").exists()) return
    val current = ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: return
    val gate = ctx.getSharedPreferences("wolium", Context.MODE_PRIVATE)
    val nowMs = System.currentTimeMillis()
    if (nowMs - gate.getLong("update_checked", 0L) < 6L * 3600L * 1000L) return
    gate.edit().putLong("update_checked", nowMs).apply()
    val latest = http("https://github.com/$REPO/releases/latest/download/version.txt").trim()
    if (!Regex("^[0-9]+(\\.[0-9]+)*$").matches(latest) || compare(current, latest) >= 0) {
      cleanUpdates(ctx)
      return
    }
    val prefs = ctx.getSharedPreferences("wolium", Context.MODE_PRIVATE)
    val file = File(updateDir(ctx), "Wolium-$latest.apk")
    if (!(file.exists() && prefs.getString("ready_version", "") == latest)) {
      updateDir(ctx).listFiles()?.forEach { it.delete() }
      if (!download("https://github.com/$REPO/releases/latest/download/Wolium.apk", file)) throw java.io.IOException("download")
      prefs.edit().putString("ready_version", latest).apply()
    }
    if (prefs.getString("notified", "") == latest) return
    val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= 26) {
      nm.createNotificationChannel(NotificationChannel("updates", text(ctx, "notifChannel"), NotificationManager.IMPORTANCE_DEFAULT))
    }
    val canInstall = Build.VERSION.SDK_INT < 26 || ctx.packageManager.canRequestPackageInstalls()
    val pending = if (canInstall) {
      val uri = androidx.core.content.FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileprovider", file)
      val view = Intent(Intent.ACTION_VIEW)
        .setDataAndType(uri, "application/vnd.android.package-archive")
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
      PendingIntent.getActivity(ctx, 0, view, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    } else {
      val intent = Intent(ctx, MainActivity::class.java).putExtra("action", "update").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
      PendingIntent.getActivity(ctx, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    val n = NotificationCompat.Builder(ctx, "updates")
      .setSmallIcon(ctx.applicationInfo.icon)
      .setContentTitle(text(ctx, "notifReadyTitle"))
      .setContentText(String.format(text(ctx, "notifReadyText"), latest))
      .setContentIntent(pending)
      .setAutoCancel(true)
      .build()
    if (!nm.areNotificationsEnabled()) return
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
    fun isEnabled(ctx: Context): Boolean {
      return try {
        ctx.getSharedPreferences("wolium", Context.MODE_PRIVATE).getBoolean("crash_logs", true)
      } catch (_: Throwable) {
        true
      }
    }

    fun clear(ctx: Context) {
      try {
        File(ctx.filesDir, "crash.txt").delete()
      } catch (_: Throwable) {
      }
      try {
        if (Build.VERSION.SDK_INT >= 29) {
          ctx.contentResolver.delete(
            android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            "${android.provider.MediaStore.Downloads.DISPLAY_NAME} LIKE ?",
            arrayOf("wolium_crash%")
          )
        }
      } catch (_: Throwable) {
      }
    }

    fun write(ctx: Context, e: Throwable) {
      try {
        if (!isEnabled(ctx)) return
        val text = android.util.Log.getStackTraceString(e)
        File(ctx.filesDir, "crash.txt").writeText(text)
        if (Build.VERSION.SDK_INT >= 29) {
          try {
            ctx.contentResolver.delete(
              android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI,
              "${android.provider.MediaStore.Downloads.DISPLAY_NAME} LIKE ?",
              arrayOf("wolium_crash%")
            )
          } catch (_: Throwable) {
          }
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
