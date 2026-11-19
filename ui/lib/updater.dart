import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'data.dart';
import 'l10n.dart';

const repository = 'arturwo1/trackwolium';

class UpdateInfo {
  UpdateInfo(this.current, this.latest, this.url);

  final String current;
  final String latest;
  final String url;
  bool ready = false;
}

String? readyInstaller(String version) {
  if (Platform.isAndroid) return null;
  try {
    final f = File('${dataDir()}${Platform.pathSeparator}update.ready');
    if (!f.existsSync()) return null;
    final lines = f.readAsStringSync().split('\n').map((e) => e.trim()).toList();
    if (lines.length < 2 || lines[0] != version) return null;
    final file = File(lines[1]);
    return file.existsSync() && file.lengthSync() > 1024 * 1024 ? file.path : null;
  } catch (_) {
    return null;
  }
}

final bool updaterSupported = Platform.isWindows || Platform.isAndroid || Platform.isLinux || Platform.isMacOS;

String updateAsset() {
  if (Platform.isAndroid) return 'Wolium.apk';
  if (Platform.isLinux) return 'Wolium-linux-x86_64.tar.gz';
  if (Platform.isMacOS) return 'Wolium-macos.zip';
  return 'WoliumSetup.exe';
}

const _buildVersion = String.fromEnvironment('WOLIUM_VERSION');

String installedVersion() {
  if (!Platform.isWindows) return _buildVersion;
  try {
    return File('${installDir()}${Platform.pathSeparator}version.txt').readAsStringSync().trim();
  } catch (_) {
    return '';
  }
}

int compareVersions(String a, String b) {
  final x = a.split('.').map((e) => int.tryParse(e.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0).toList();
  final y = b.split('.').map((e) => int.tryParse(e.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0).toList();
  final n = x.length > y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    final p = i < x.length ? x[i] : 0;
    final q = i < y.length ? y[i] : 0;
    if (p != q) return p < q ? -1 : 1;
  }
  return 0;
}

Future<String> _get(HttpClient client, Uri uri) async {
  final req = await client.getUrl(uri);
  req.headers.set('User-Agent', 'Wolium');
  req.headers.set('Accept', 'application/vnd.github+json');
  final res = await req.close();
  if (res.statusCode != 200) throw HttpException('status ${res.statusCode}');
  return utf8.decode(await res.fold<List<int>>([], (a, b) => a..addAll(b)));
}

String lastUpdateStatus = '';

void _status(String current, String latest, String code) {
  final t = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  lastUpdateStatus = '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)} | ${current.isEmpty ? '?' : current} -> ${latest.isEmpty ? '?' : latest} | $code';
}

const _statusKeys = {
  'no consent': 'usNoConsent',
  'updates disabled': 'usDisabled',
  'check failed': 'usCheckFailed',
  'installed version unknown': 'usUnknownVersion',
  'up to date': 'usUpToDate',
  'download failed': 'usDownloadFailed',
  'ready, deferred (do not disturb)': 'usDeferred',
  'installing silently': 'usInstalling',
  'silent install failed': 'usSilentFailed',
  'ready, waiting for the window': 'usWaitingWindow',
  'update available': 'usAvailable',
};

String translateUpdateStatus(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return '';
  final parts = text.split(' | ');
  if (parts.length < 3) return text;
  final code = parts.sublist(2).join(' | ').trim();
  final key = _statusKeys[code];
  return '${parts[0]} | ${parts[1]} | ${key == null ? code : tr(key)}';
}

Future<UpdateInfo?> checkUpdate() async {
  final current = installedVersion();
  if (current.isEmpty || !updaterSupported) {
    _status(current, '', 'installed version unknown');
    return null;
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  var latest = '';
  try {
    latest = (await _get(client, Uri.parse('https://github.com/$repository/releases/latest/download/version.txt'))).trim();
    if (latest.isEmpty || !RegExp(r'^[0-9]+(\.[0-9]+)*$').hasMatch(latest)) {
      _status(current, '', 'check failed');
      return null;
    }
    if (compareVersions(current, latest) >= 0) {
      _status(current, latest, 'up to date');
      return null;
    }
    final setupUrl = 'https://github.com/$repository/releases/latest/download/${updateAsset()}';
    final info = UpdateInfo(current, latest, setupUrl);
    info.ready = readyInstaller(latest) != null;
    _status(current, latest, 'update available');
    return info;
  } catch (_) {
    _status(current, latest, 'check failed');
    return null;
  } finally {
    client.close(force: true);
  }
}

String updateNote = '';
String readyApk = '';

Future<bool> downloadAndInstall(UpdateInfo info, void Function(double) progress) async {
  updateNote = '';
  if (Platform.isAndroid) {
    try {
      final path = await const MethodChannel('wolium/usage').invokeMethod<String>('readyApk');
      if (path != null && path.contains('Wolium-${info.latest}.apk') && File(path).existsSync()) {
        progress(1);
        return await installApk(path);
      }
    } catch (_) {}
    if (readyApk.isNotEmpty && File(readyApk).existsSync()) {
      progress(1);
      return await installApk(readyApk);
    }
  }
  final preloaded = readyInstaller(info.latest);
  if (preloaded != null) {
    progress(1);
    try {
      if (Platform.isLinux) return await installLinux(preloaded);
      if (Platform.isMacOS) return await installMac(preloaded);
      await Process.start(preloaded, ['--silent', installDir()], mode: ProcessStartMode.detached);
      return true;
    } catch (e) {
      updateNote = e.toString();
      return false;
    }
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final tempDir = Platform.isAndroid ? (await getTemporaryDirectory()).path : Directory.systemTemp.path;
  final target = File('$tempDir${Platform.pathSeparator}${Platform.isWindows ? 'WoliumSetup_update.exe' : 'Wolium_update_${updateAsset()}'}');
  try {
    final req = await client.getUrl(Uri.parse(info.url));
    req.headers.set('User-Agent', 'Wolium');
    final res = await req.close();
    if (res.statusCode != 200) {
      updateNote = 'HTTP ${res.statusCode}';
      return false;
    }
    final total = res.contentLength;
    var got = 0;
    final sink = target.openWrite();
    await for (final chunk in res) {
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) progress(got / total);
    }
    await sink.close();
    if (total > 0 && got != total) {
      updateNote = '$got/$total';
      return false;
    }
    if (Platform.isAndroid) {
      readyApk = target.path;
      return await installApk(target.path);
    }
    if (Platform.isLinux) return await installLinux(target.path);
    if (Platform.isMacOS) return await installMac(target.path);
    await Process.start(target.path, ['--silent', installDir()], mode: ProcessStartMode.detached);
    return true;
  } catch (e) {
    updateNote = e.toString();
    return false;
  } finally {
    client.close(force: true);
  }
}

Future<bool> installApk(String path) async {
  try {
    final r = await const MethodChannel('wolium/usage').invokeMethod<String>('installApk', {'path': path});
    if (r == 'ok') return true;
    updateNote = r == 'permission' ? 'permission' : (r ?? '');
    return false;
  } catch (e) {
    updateNote = e.toString();
    return false;
  }
}

Future<bool> installLinux(String archive) async {
  final work = Directory('${Directory.systemTemp.path}/wolium_update')..createSync(recursive: true);
  final r = await Process.run('tar', ['-xzf', archive, '-C', work.path]);
  if (r.exitCode != 0) return false;
  final script = '${work.path}/wolium-linux/install.sh';
  if (!File(script).existsSync()) return false;
  await Process.start('sh', ['-c', 'sleep 1; sh "\$0" --update', script], mode: ProcessStartMode.detached);
  return true;
}

Future<bool> installMac(String archive) async {
  final bundle = File(Platform.resolvedExecutable).parent.parent.parent.path;
  if (!bundle.endsWith('.app')) return false;
  final work = Directory('${Directory.systemTemp.path}/wolium_update')..createSync(recursive: true);
  final r = await Process.run('ditto', ['-x', '-k', archive, work.path]);
  if (r.exitCode != 0) return false;
  final fresh = '${work.path}/Wolium.app';
  if (!Directory(fresh).existsSync()) return false;
  const script = 'sleep 1; pkill -f "\$2/Contents/MacOS/trackwolium-core"; rm -rf "\$2" && mv "\$1" "\$2" && xattr -dr com.apple.quarantine "\$2"; open "\$2"';
  await Process.start('sh', ['-c', script, 'wolium', fresh, bundle], mode: ProcessStartMode.detached);
  return true;
}
