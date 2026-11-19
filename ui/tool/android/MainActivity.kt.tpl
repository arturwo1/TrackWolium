package __PACKAGE__

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
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
    Thread.setDefaultUncaughtExceptionHandler(CrashLog(applicationContext, Thread.getDefaultUncaughtExceptionHandler()))
    super.onCreate(savedInstanceState)
    action = intent?.getStringExtra("action")
    try {
      val request = PeriodicWorkRequestBuilder<SyncWorker>(3, TimeUnit.HOURS).build()
      WorkManager.getInstance(applicationContext).enqueueUniquePeriodicWork("wolium-sync", ExistingPeriodicWorkPolicy.UPDATE, request)
      val builder = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.UNMETERED)
        .setRequiresCharging(true)
      if (Build.VERSION.SDK_INT >= 23) builder.setRequiresDeviceIdle(true)
      val constraints = builder.build()
      val check = PeriodicWorkRequestBuilder<UpdateWorker>(24, TimeUnit.HOURS)
        .setConstraints(constraints)
        .setBackoffCriteria(androidx.work.BackoffPolicy.EXPONENTIAL, 30, TimeUnit.MINUTES)
        .build()
      WorkManager.getInstance(applicationContext).enqueueUniquePeriodicWork("wolium-update", ExistingPeriodicWorkPolicy.UPDATE, check)
    } catch (ex: Throwable) {
      CrashLog.write(applicationContext, ex)
    }
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
        "openApp" -> {
          val pkg = call.argument<String>("pkg") ?: ""
          val launch = try {
            packageManager.getLaunchIntentForPackage(pkg)
          } catch (ex: Exception) {
            null
          }
          if (launch == null) {
            result.success(false)
          } else {
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            result.success(try {
              startActivity(launch)
              true
            } catch (ex: Exception) {
              false
            })
          }
        }
        "appInfo" -> {
          val pkg = call.argument<String>("pkg") ?: ""
          result.success(try {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + pkg)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
          } catch (ex: Exception) {
            false
          })
        }
        "uninstallApp" -> {
          val pkg = call.argument<String>("pkg") ?: ""
          result.success(try {
            startActivity(Intent(Intent.ACTION_DELETE, Uri.parse("package:" + pkg)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
          } catch (ex: Exception) {
            false
          })
        }
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
        "deviceName" -> {
          val maker = Build.MANUFACTURER ?: ""
          val model = Build.MODEL ?: ""
          val brand = if (maker.isEmpty()) "" else maker.substring(0, 1).uppercase() + maker.substring(1)
          result.success(if (model.lowercase().startsWith(maker.lowercase())) model else "$brand $model".trim())
        }
        "readyApk" -> {
          result.success(try {
            Sync.readyApk(applicationContext)?.path
          } catch (ex: Exception) {
            null
          })
        }
        "requestNotifications" -> {
          if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 77)
          result.success(null)
        }
        "apiService" -> {
          var outcome = "ok"
          try {
            ApiService.apply(applicationContext, call.argument<Boolean>("on") ?: false)
          } catch (ex: Exception) {
            outcome = "error: " + ex.toString()
          }
          result.success(outcome)
        }
        "vibrate" -> {
          try {
            val ms = (call.argument<Int>("ms") ?: 10).toLong()
            val amp = call.argument<Int>("amp") ?: 80
            val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            if (Build.VERSION.SDK_INT >= 26) {
              val strength = if (vibrator.hasAmplitudeControl()) amp.coerceIn(1, 255) else VibrationEffect.DEFAULT_AMPLITUDE
              vibrator.vibrate(VibrationEffect.createOneShot(ms, strength))
            } else {
              vibrator.vibrate(ms)
            }
          } catch (ex: Exception) {
          }
          result.success(null)
        }
        "installApk" -> {
          try {
            if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
              startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
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
          } catch (ex: Exception) {
            result.success("error: " + ex.toString())
          }
        }
        else -> result.notImplemented()
      }
    }
  }
}
