package __PACKAGE__

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
  private var pendingResult: MethodChannel.Result? = null
  private var pendingBytes: ByteArray? = null
  private var action: String? = null

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    action = intent?.getStringExtra("action")
    val request = PeriodicWorkRequestBuilder<SyncWorker>(6, TimeUnit.HOURS).build()
    WorkManager.getInstance(applicationContext).enqueueUniquePeriodicWork("wolium-sync", ExistingPeriodicWorkPolicy.KEEP, request)
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    action = intent.getStringExtra("action")
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    if (requestCode == 4711) {
      val r = pendingResult
      pendingResult = null
      val uri = data?.data
      if (resultCode == RESULT_OK && uri != null) {
        try {
          contentResolver.openOutputStream(uri)?.use { it.write(pendingBytes ?: ByteArray(0)) }
          r?.success(uri.toString())
        } catch (ex: Exception) {
          r?.success(null)
        }
      } else {
        r?.success(null)
      }
      pendingBytes = null
      return
    }
    if (requestCode == 4712) {
      val r = pendingResult
      pendingResult = null
      val uri = data?.data
      if (resultCode == RESULT_OK && uri != null) {
        try {
          r?.success(contentResolver.openInputStream(uri)?.use { it.readBytes() })
        } catch (ex: Exception) {
          r?.success(null)
        }
      } else {
        r?.success(null)
      }
      return
    }
    super.onActivityResult(requestCode, resultCode, data)
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wolium/usage").setMethodCallHandler { call, result ->
      when (call.method) {
        "hasAccess" -> result.success(Sync.hasAccess(this))
        "openSettings" -> {
          startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
          result.success(null)
        }
        "events" -> {
          val from = (call.argument<Number>("from") ?: 0).toLong()
          val to = (call.argument<Number>("to") ?: 0).toLong()
          result.success(Sync.events(this, from, to))
        }
        "label" -> result.success(Sync.label(this, call.argument<String>("pkg") ?: ""))
        "icon" -> result.success(Sync.icon(this, call.argument<String>("pkg") ?: ""))
        "saveFile" -> {
          pendingBytes = call.argument<ByteArray>("bytes")
          pendingResult = result
          val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(call.argument<String>("mime") ?: "text/csv")
            .putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "wolium.csv")
          startActivityForResult(intent, 4711)
        }
        "openUri" -> {
          try {
            val view = Intent(Intent.ACTION_VIEW)
              .setDataAndType(Uri.parse(call.argument<String>("uri") ?: ""), "text/csv")
              .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(Intent.createChooser(view, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
          } catch (ex: Exception) {
          }
          result.success(null)
        }
        "pickFile" -> {
          pendingResult = result
          val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
          startActivityForResult(intent, 4712)
        }
        "takeAction" -> {
          val a = action
          action = null
          result.success(a)
        }
        "requestNotifications" -> {
          if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 77)
          result.success(null)
        }
        "installApk" -> {
          if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            result.success("permission")
          } else {
            val file = File(call.argument<String>("path") ?: "")
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val view = Intent(Intent.ACTION_VIEW)
              .setDataAndType(uri, "application/vnd.android.package-archive")
              .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(view)
            result.success("ok")
          }
        }
        else -> result.notImplemented()
      }
    }
  }
}
