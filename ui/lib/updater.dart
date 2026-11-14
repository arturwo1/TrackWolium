import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'data.dart';

const repository = 'arturwo1/trackwolium';

class UpdateInfo {
  UpdateInfo(this.current, this.latest, this.url);

  final String current;
  final String latest;
  final String url;
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

Future<UpdateInfo?> checkUpdate() async {
  final current = installedVersion();
  if (current.isEmpty || !updaterSupported) return null;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final body = await _get(client, Uri.parse('https://api.github.com/repos/$repository/releases/latest'));
    final json = jsonDecode(body) as Map<String, dynamic>;
    String? versionUrl;
    String? setupUrl;
    for (final a in (json['assets'] as List<dynamic>? ?? [])) {
      final m = a as Map<String, dynamic>;
      if (m['name'] == 'version.txt') versionUrl = m['browser_download_url'] as String?;
      if (m['name'] == updateAsset()) setupUrl = m['browser_download_url'] as String?;
    }
    if (versionUrl == null || setupUrl == null) return null;
    final latest = (await _get(client, Uri.parse(versionUrl))).trim();
    if (latest.isEmpty || compareVersions(current, latest) >= 0) return null;
    return UpdateInfo(current, latest, setupUrl);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<bool> downloadAndInstall(UpdateInfo info, void Function(double) progress) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final target = File('${Directory.systemTemp.path}${Platform.pathSeparator}${Platform.isWindows ? 'WoliumSetup_update.exe' : 'Wolium_update_${updateAsset()}'}');
  try {
    final req = await client.getUrl(Uri.parse(info.url));
    req.headers.set('User-Agent', 'Wolium');
    final res = await req.close();
    if (res.statusCode != 200) return false;
    final total = res.contentLength;
    var got = 0;
    final sink = target.openWrite();
    await for (final chunk in res) {
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) progress(got / total);
    }
    await sink.close();
    if (total > 0 && got != total) return false;
    if (Platform.isAndroid) return await installApk(target.path);
    if (Platform.isLinux) return await installLinux(target.path);
    if (Platform.isMacOS) return await installMac(target.path);
    await Process.start(target.path, ['--silent', installDir()], mode: ProcessStartMode.detached);
    return true;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

Future<bool> installApk(String path) async {
  final r = await const MethodChannel('wolium/usage').invokeMethod<String>('installApk', {'path': path});
  return r == 'ok';
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
