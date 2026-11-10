import 'dart:convert';
import 'dart:io';
import 'data.dart';

const repository = 'arturwo1/trackwolium';

class UpdateInfo {
  UpdateInfo(this.current, this.latest, this.url);

  final String current;
  final String latest;
  final String url;
}

String installedVersion() {
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
  if (current.isEmpty) return null;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final body = await _get(client, Uri.parse('https://api.github.com/repos/$repository/releases/latest'));
    final json = jsonDecode(body) as Map<String, dynamic>;
    String? versionUrl;
    String? setupUrl;
    for (final a in (json['assets'] as List<dynamic>? ?? [])) {
      final m = a as Map<String, dynamic>;
      if (m['name'] == 'version.txt') versionUrl = m['browser_download_url'] as String?;
      if (m['name'] == 'WoliumSetup.exe') setupUrl = m['browser_download_url'] as String?;
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
  final target = File('${Directory.systemTemp.path}${Platform.pathSeparator}WoliumSetup_update.exe');
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
    await Process.start(target.path, ['--silent', installDir()], mode: ProcessStartMode.detached);
    return true;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}
