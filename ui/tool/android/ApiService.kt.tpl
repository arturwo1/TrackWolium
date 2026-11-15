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
      val buf = ByteArray(8192)
      var len = 0
      while (len < buf.size) {
        val n = input.read(buf, len, buf.size - len)
        if (n <= 0) break
        len += n
        if (String(buf, 0, len, Charsets.ISO_8859_1).contains("\r\n\r\n")) break
      }
      val request = String(buf, 0, len, Charsets.ISO_8859_1)
      val lines = request.split("\r\n")
      val parts = lines.firstOrNull()?.split(" ") ?: emptyList()
      var host = ""
      for (l in lines.drop(1)) {
        val i = l.indexOf(':')
        if (i > 0 && l.substring(0, i).trim().equals("host", true)) host = l.substring(i + 1).trim().lowercase(Locale.ROOT)
      }
      val response = when {
        parts.size < 3 || parts[0] != "GET" || !parts[2].startsWith("HTTP/1.") || (host != "127.0.0.1:$PORT" && host != "localhost:$PORT") ->
          http(400, "{\"error\":\"bad request\"}")
        parts[1] != "/v1/current" -> http(404, "{\"error\":\"not found\"}")
        else -> http(200, current())
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

  private fun http(status: Int, body: String): String {
    val text = when (status) {
      200 -> "OK"
      404 -> "Not Found"
      else -> "Bad Request"
    }
    val bytes = body.toByteArray(Charsets.UTF_8).size
    return "HTTP/1.1 $status $text\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: $bytes\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n$body"
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
