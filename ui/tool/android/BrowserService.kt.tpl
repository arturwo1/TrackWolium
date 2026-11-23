package __PACKAGE__

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import android.os.PowerManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.io.File
import java.net.URI
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

class BrowserService : AccessibilityService() {
  private var activeBrowser = ""
  private var activeDomain = ""
  private var activeUrl = ""
  private var activeTitle = ""
  private var activeSince = 0L

  private val browserMap = mapOf(
    "com.android.chrome" to "chrome",
    "com.chrome.beta" to "chrome",
    "com.chrome.dev" to "chrome",
    "com.chrome.canary" to "chrome",
    "org.chromium.chrome" to "chrome",
    "com.opera.browser" to "opera",
    "com.opera.browser.beta" to "opera",
    "com.opera.gx" to "opera",
    "com.opera.mini.native" to "opera",
    "com.opera.touch" to "opera",
    "org.mozilla.firefox" to "firefox",
    "org.mozilla.firefox_beta" to "firefox",
    "org.mozilla.fenix" to "firefox",
    "org.mozilla.focus" to "firefox",
    "io.github.forkmaintainers.iceraven" to "firefox",
    "com.brave.browser" to "brave",
    "com.microsoft.emmx" to "edge",
    "com.vivaldi.browser" to "vivaldi",
    "com.yandex.browser" to "yandex",
    "com.sec.android.app.sbrowser" to "samsung",
    "com.duckduckgo.mobile.android" to "duckduckgo",
    "com.kiwibrowser.browser" to "kiwi",
    "com.UCMobile.intl" to "uc",
    "com.mi.globalbrowser" to "miui"
  )

  private val urlIdHints = listOf(
    "url_bar",
    "mozac_browser_toolbar_url_view",
    "location_bar_edit_text",
    "url_field",
    "search_box_text",
    "omnibox_url_text",
    "address_bar",
    "url"
  )

  override fun onServiceConnected() {
    super.onServiceConnected()
  }

  override fun onInterrupt() {
    flushActive(System.currentTimeMillis())
  }

  override fun onDestroy() {
    flushActive(System.currentTimeMillis())
    super.onDestroy()
  }

  override fun onAccessibilityEvent(event: AccessibilityEvent?) {
    if (event == null) return
    val now = System.currentTimeMillis()
    val dir = Sync.dir(applicationContext)
    if (!File(dir, "consent").exists() || File(dir, "paused").exists()) {
      flushActive(now)
      clearActive()
      return
    }
    val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
    if (pm != null && Build.VERSION.SDK_INT >= 20 && !pm.isInteractive) {
      flushActive(now)
      clearActive()
      return
    }

    val root = rootInActiveWindow
    val pkg = root?.packageName?.toString() ?: event.packageName?.toString() ?: ""
    val browserId = browserMap[pkg]
    if (browserId == null || root == null) {
      if (pkg.isNotEmpty() && pkg != packageName && !pkg.startsWith("com.android.systemui")) {
        flushActive(now)
        clearActive()
      }
      return
    }

    val rawUrl = findUrlText(root)
    val parsed = parseUrlAndDomain(rawUrl)
    if (parsed == null) {
      flushActive(now)
      return
    }
    val (domain, fullUrl) = parsed
    val candidateTitle = findTitleText(root, event, domain)

    if (browserId == activeBrowser && domain == activeDomain) {
      if (candidateTitle.isNotEmpty() && candidateTitle != activeTitle) {
        activeTitle = candidateTitle
        if (fullUrl.isNotEmpty()) activeUrl = fullUrl
        recordUsage(browserId, domain, activeTitle, activeUrl, 1L, now)
      }
      flushActive(now)
      if (fullUrl.isNotEmpty()) activeUrl = fullUrl
      return
    }

    flushActive(now)
    activeBrowser = browserId
    activeDomain = domain
    activeUrl = fullUrl
    activeTitle = candidateTitle
    activeSince = now
  }

  private fun clearActive() {
    activeBrowser = ""
    activeDomain = ""
    activeUrl = ""
    activeTitle = ""
    activeSince = 0L
  }

  private fun flushActive(now: Long) {
    if (activeBrowser.isEmpty() || activeDomain.isEmpty() || activeSince <= 0L) {
      activeSince = now
      return
    }
    val delta = (now - activeSince).coerceAtMost(120000L)
    activeSince = now
    if (delta >= 500L) {
      recordUsage(activeBrowser, activeDomain, activeTitle, activeUrl, delta, now)
    }
  }

  private fun findUrlText(root: AccessibilityNodeInfo): String {
    for (hint in urlIdHints) {
      val list = findByIdSuffix(root, hint)
      for (n in list) {
        val txt = n.text?.toString()?.trim() ?: ""
        if (looksLikeDomainOrUrl(txt)) return txt
      }
    }
    return scanForUrl(root, 0)
  }

  private fun findByIdSuffix(node: AccessibilityNodeInfo, suffix: String): List<AccessibilityNodeInfo> {
    val out = ArrayList<AccessibilityNodeInfo>()
    fun walk(n: AccessibilityNodeInfo, depth: Int) {
      if (depth > 14) return
      val vid = n.viewIdResourceName ?: ""
      if (vid.endsWith(":id/$suffix") || vid == suffix) out.add(n)
      for (i in 0 until n.childCount) {
        val ch = n.getChild(i) ?: continue
        walk(ch, depth + 1)
      }
    }
    walk(node, 0)
    return out
  }

  private fun scanForUrl(node: AccessibilityNodeInfo, depth: Int): String {
    if (depth > 12) return ""
    val txt = node.text?.toString()?.trim() ?: ""
    val cls = node.className?.toString() ?: ""
    if ((cls.contains("EditText") || cls.contains("TextView")) && looksLikeDomainOrUrl(txt)) {
      if (txt.contains("://") || (!txt.contains(' ') && txt.contains('.'))) return txt
    }
    for (i in 0 until node.childCount) {
      val ch = node.getChild(i) ?: continue
      val found = scanForUrl(ch, depth + 1)
      if (found.isNotEmpty()) return found
    }
    return ""
  }

  private fun findTitleText(root: AccessibilityNodeInfo, event: AccessibilityEvent, domain: String): String {
    val winTitle = if (Build.VERSION.SDK_INT >= 24) root.window?.title?.toString()?.trim() ?: "" else ""
    if (!isBadTitle(winTitle, domain)) return winTitle.take(180)
    for (evText in event.text) {
      val s = evText?.toString()?.trim() ?: ""
      if (s.length in 3..180 && !isBadTitle(s, domain) && !looksLikeUiLabel(s)) return s
    }
    fun walkWeb(node: AccessibilityNodeInfo, depth: Int): String {
      if (depth > 12) return ""
      val cls = node.className?.toString() ?: ""
      if (cls.contains("WebView")) {
        val desc = node.contentDescription?.toString()?.trim() ?: ""
        if (desc.length in 3..180 && !isBadTitle(desc, domain)) return desc
      }
      val vid = node.viewIdResourceName ?: ""
      if (vid.endsWith(":id/title") || vid.endsWith(":id/tab_title") || vid.endsWith(":id/page_title")) {
        val t = node.text?.toString()?.trim() ?: ""
        if (t.length in 3..180 && !isBadTitle(t, domain)) return t
      }
      for (i in 0 until node.childCount) {
        val ch = node.getChild(i) ?: continue
        val f = walkWeb(ch, depth + 1)
        if (f.isNotEmpty()) return f
      }
      return ""
    }
    return walkWeb(root, 0).take(180)
  }

  private fun looksLikeUiLabel(s: String): Boolean {
    val l = s.lowercase(Locale.ROOT)
    return l == "chrome" || l == "opera" || l == "firefox" || l == "brave" || l == "edge" || l == "vivaldi" || l.startsWith("search or type")
  }

  private fun looksLikeDomainOrUrl(raw: String): Boolean {
    if (raw.length < 3 || raw.length > 512) return false
    val s = raw.trim()
    if (s.contains(' ') && !s.startsWith("http://") && !s.startsWith("https://")) return false
    if (s.startsWith("about:") || s.startsWith("chrome:") || s.startsWith("edge:") || s.startsWith("opera:") || s.startsWith("file:")) return false
    return s.startsWith("http://") || s.startsWith("https://") || Regex("^[a-zA-Z0-9-]+(\\.[a-zA-Z0-9-]+)+([:/?#].*)?$").matches(s)
  }

  private fun parseUrlAndDomain(raw: String): Pair<String, String>? {
    if (raw.isEmpty()) return null
    val norm = if (raw.startsWith("http://") || raw.startsWith("https://")) raw else "https://$raw"
    return try {
      val uri = URI(norm)
      var host = (uri.host ?: "").lowercase(Locale.ROOT)
      if (host.startsWith("www.")) host = host.substring(4)
      if (host.isEmpty() || !host.contains('.') || host.length > 192) return null
      val url = if (raw.startsWith("http://") || raw.startsWith("https://")) norm.take(512) else "https://$raw".take(512)
      Pair(host, url)
    } catch (_: Exception) {
      null
    }
  }

  private fun isBadTitle(title: String, domain: String): Boolean {
    val t = title.replace(Regex("[\\u0000-\\u001F]"), " ").replace(Regex("\\s+"), " ").trim().lowercase(Locale.ROOT)
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

  private fun recordUsage(browser: String, domain: String, title: String, url: String, ms: Long, nowMs: Long) {
    val cleanT = if (isBadTitle(title, domain)) "" else title.replace(Regex("[\\u0000-\\u001F]"), " ").replace(Regex("\\s+"), " ").trim().take(180)
    val day = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(nowMs))
    val cal = Calendar.getInstance().apply { timeInMillis = nowMs }
    val slot = ((cal.get(Calendar.HOUR_OF_DAY) * 3600 + cal.get(Calendar.MINUTE) * 60 + cal.get(Calendar.SECOND)) / 300).coerceIn(0, 287)
    try {
      val dir = Sync.dir(applicationContext)
      dir.mkdirs()
      val db = SQLiteDatabase.openOrCreateDatabase(File(dir, "usage.db"), null)
      try {
        db.enableWriteAheadLogging()
        db.execSQL("CREATE TABLE IF NOT EXISTS browser_usage(day TEXT NOT NULL, browser TEXT NOT NULL, domain TEXT NOT NULL, ms INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '', url TEXT NOT NULL DEFAULT '', PRIMARY KEY(day, browser, domain)) WITHOUT ROWID")
        db.execSQL("CREATE TABLE IF NOT EXISTS browser_timeline(day TEXT NOT NULL, slot INTEGER NOT NULL, browser TEXT NOT NULL, domain TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', ms INTEGER NOT NULL, PRIMARY KEY(day, slot, browser, domain)) WITHOUT ROWID")
        db.beginTransaction()
        try {
          db.execSQL(
            "INSERT INTO browser_usage(day, browser, domain, ms, title, url) VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(day, browser, domain) DO UPDATE SET ms = ms + excluded.ms, title = CASE WHEN excluded.title != '' THEN excluded.title ELSE browser_usage.title END, url = CASE WHEN excluded.url != '' THEN excluded.url ELSE browser_usage.url END",
            arrayOf<Any>(day, browser, domain, ms, cleanT, url)
          )
          db.execSQL(
            "INSERT INTO browser_timeline(day, slot, browser, domain, title, ms) VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(day, slot, browser, domain) DO UPDATE SET ms = ms + excluded.ms, title = CASE WHEN excluded.title != '' THEN excluded.title ELSE browser_timeline.title END",
            arrayOf<Any>(day, slot, browser, domain, cleanT, ms)
          )
          db.setTransactionSuccessful()
        } finally {
          db.endTransaction()
        }
      } finally {
        db.close()
      }
    } catch (_: Exception) {
    }
  }
}
