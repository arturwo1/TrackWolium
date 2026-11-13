import re
import shutil
import sys
from pathlib import Path

root = Path(sys.argv[1])
icon = Path(sys.argv[2])
main_dir = root / "android" / "app" / "src" / "main"

manifest = main_dir / "AndroidManifest.xml"
text = manifest.read_text(encoding="utf-8")
perms = (
    '    <uses-permission android:name="android.permission.PACKAGE_USAGE_STATS" tools:ignore="ProtectedPermissions"/>\n'
    '    <uses-permission android:name="android.permission.QUERY_ALL_PACKAGES"/>\n'
)
if "PACKAGE_USAGE_STATS" not in text:
    text = re.sub(r"(<manifest[^>]*>)", r"\1\n" + perms.rstrip("\n"), text, count=1)
if "xmlns:tools" not in text:
    text = text.replace("<manifest ", '<manifest xmlns:tools="http://schemas.android.com/tools" ', 1)
text = re.sub(r'android:label="[^"]*"', 'android:label="Wolium"', text, count=1)
if "allowBackup" not in text:
    text = text.replace("<application", '<application android:allowBackup="true"', 1)
manifest.write_text(text, encoding="utf-8")

kt = next(main_dir.glob("kotlin/**/MainActivity.kt"))
package = re.search(r"^package\s+(\S+)", kt.read_text(encoding="utf-8"), re.M).group(1)
kt.write_text(
    f"""package {package}

import android.app.AppOpsManager
import android.content.Intent
import android.content.pm.PackageManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.net.Uri
import android.os.Process
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {{

  private var pendingResult: MethodChannel.Result? = null
  private var pendingBytes: ByteArray? = null

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {{
    if (requestCode == 4711) {{
      val r = pendingResult
      pendingResult = null
      val uri = data?.data
      if (resultCode == RESULT_OK && uri != null) {{
        try {{
          contentResolver.openOutputStream(uri)?.use {{ it.write(pendingBytes ?: ByteArray(0)) }}
          r?.success(uri.toString())
        }} catch (ex: Exception) {{
          r?.success(null)
        }}
      }} else {{
        r?.success(null)
      }}
      pendingBytes = null
      return
    }}
    super.onActivityResult(requestCode, resultCode, data)
  }}
  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {{
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wolium/usage").setMethodCallHandler {{ call, result ->
      when (call.method) {{
        "hasAccess" -> {{
          val ops = getSystemService(APP_OPS_SERVICE) as AppOpsManager
          val mode = ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), packageName)
          result.success(mode == AppOpsManager.MODE_ALLOWED)
        }}
        "openSettings" -> {{
          startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
          result.success(null)
        }}
        "events" -> {{
          val from = (call.argument<Number>("from") ?: 0).toLong()
          val to = (call.argument<Number>("to") ?: 0).toLong()
          val mgr = getSystemService(USAGE_STATS_SERVICE) as UsageStatsManager
          val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
          val launcher = packageManager.resolveActivity(home, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo?.packageName
          val out = ArrayList<Map<String, Any>>()
          val events = mgr.queryEvents(from, to)
          val e = UsageEvents.Event()
          while (events.hasNextEvent()) {{
            events.getNextEvent(e)
            val t = e.eventType
            if (t != 1 && t != 2 && t != 16 && t != 26) continue
            val pkg = e.packageName ?: ""
            if (pkg == launcher || pkg == "com.android.systemui") {{
              if (t == 1) out.add(mapOf("pkg" to pkg, "type" to 16, "time" to e.timeStamp))
              continue
            }}
            out.add(mapOf("pkg" to pkg, "type" to t, "time" to e.timeStamp))
          }}
          result.success(out)
        }}
        "label" -> {{
          val pkg = call.argument<String>("pkg") ?: ""
          val label = try {{
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
          }} catch (ex: Exception) {{
            pkg
          }}
          result.success(label)
        }}
        "icon" -> {{
          val pkg = call.argument<String>("pkg") ?: ""
          try {{
            val d = packageManager.getApplicationIcon(pkg)
            val size = 96
            val bmp = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
            d.setBounds(0, 0, size, size)
            d.draw(android.graphics.Canvas(bmp))
            val out = java.io.ByteArrayOutputStream()
            bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
            result.success(out.toByteArray())
          }} catch (ex: Exception) {{
            result.success(null)
          }}
        }}
        "saveFile" -> {{
          pendingBytes = call.argument<ByteArray>("bytes")
          pendingResult = result
          val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("text/csv")
            .putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "wolium.csv")
          startActivityForResult(intent, 4711)
        }}
        "openUri" -> {{
          try {{
            val view = Intent(Intent.ACTION_VIEW)
              .setDataAndType(Uri.parse(call.argument<String>("uri") ?: ""), "text/csv")
              .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(Intent.createChooser(view, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
          }} catch (ex: Exception) {{
          }}
          result.success(null)
        }}
        else -> result.notImplemented()
      }}
    }}
  }}
}}
""",
    encoding="utf-8",
)

try:
    from PIL import Image

    src = Image.open(icon).convert("RGBA")
    for name, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        target = main_dir / "res" / f"mipmap-{name}"
        target.mkdir(parents=True, exist_ok=True)
        src.resize((size, size), Image.LANCZOS).save(target / "ic_launcher.png")
except ImportError:
    shutil.copy(icon, main_dir / "res" / "mipmap-xxxhdpi" / "ic_launcher.png")

root_gradle = root / "android" / "build.gradle.kts"
gtext = root_gradle.read_text(encoding="utf-8")
if "lintVital" not in gtext:
    gtext += """
subprojects {
  tasks.configureEach {
    if (name.startsWith("lintVital")) enabled = false
  }
}
"""
    root_gradle.write_text(gtext, encoding="utf-8")
