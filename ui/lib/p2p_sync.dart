import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'data.dart';

const int kP2pPort = 9096;

class PeerDevice {
  PeerDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.host,
    required this.port,
    required this.token,
    this.lastSync = 0,
  });

  final String id;
  final String name;
  final String platform;
  final String host;
  final int port;
  final String token;
  final int lastSync;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'platform': platform,
        'host': host,
        'port': port,
        'token': token,
        'lastSync': lastSync,
      };

  static PeerDevice fromJson(Map<String, dynamic> m) => PeerDevice(
        id: m['id'] as String? ?? '',
        name: m['name'] as String? ?? 'Device',
        platform: m['platform'] as String? ?? 'unknown',
        host: m['host'] as String? ?? '',
        port: (m['port'] as num?)?.toInt() ?? kP2pPort,
        token: m['token'] as String? ?? '',
        lastSync: (m['lastSync'] as num?)?.toInt() ?? 0,
      );
}

class P2pSync {
  P2pSync._();
  static final P2pSync instance = P2pSync._();

  final ValueNotifier<List<PeerDevice>> peers = ValueNotifier<List<PeerDevice>>([]);
  final ValueNotifier<String?> activePin = ValueNotifier<String?>(null);
  final ValueNotifier<int> version = ValueNotifier<int>(0);
  final ValueNotifier<bool> running = ValueNotifier<bool>(false);

  HttpServer? _server;
  Timer? _autoTimer;
  Timer? _pinTimer;
  DateTime? _pinExpires;
  String? _deviceId;

  static String get _peersFile => '${dataDir()}${Platform.pathSeparator}peers.json';
  static String get _idFile => '${dataDir()}${Platform.pathSeparator}device_id';
  static String get _flagFile => '${dataDir()}${Platform.pathSeparator}p2p';

  bool get enabled => File(_flagFile).existsSync();

  String get deviceId {
    if (_deviceId != null) return _deviceId!;
    try {
      final f = File(_idFile);
      if (f.existsSync()) {
        final s = f.readAsStringSync().trim();
        if (s.isNotEmpty) return _deviceId = s;
      }
      Directory(dataDir()).createSync(recursive: true);
      final rng = Random.secure();
      final bytes = List.generate(12, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      f.writeAsStringSync(bytes);
      return _deviceId = bytes;
    } catch (_) {
      return _deviceId = 'local-device';
    }
  }

  String get deviceName {
    try {
      final h = Platform.localHostname.trim();
      if (h.isNotEmpty && h != 'localhost') return h;
    } catch (_) {}
    return Platform.isAndroid ? 'Android' : 'Wolium PC';
  }

  String get platformName => Platform.operatingSystem;

  static void ensureSchema(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS browser_usage(day TEXT NOT NULL, browser TEXT NOT NULL, domain TEXT NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(day, browser, domain)) WITHOUT ROWID;
      CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL, host TEXT NOT NULL DEFAULT '', port INTEGER NOT NULL DEFAULT 9096, last_sync INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
      CREATE TABLE IF NOT EXISTS remote_usage(device TEXT NOT NULL, day TEXT NOT NULL, app TEXT NOT NULL, state INTEGER NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(device, day, app, state)) WITHOUT ROWID;
      CREATE TABLE IF NOT EXISTS remote_timeline(device TEXT NOT NULL, day TEXT NOT NULL, slot INTEGER NOT NULL, app TEXT NOT NULL, state INTEGER NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(device, day, slot, app, state)) WITHOUT ROWID;
      CREATE TABLE IF NOT EXISTS remote_apps(device TEXT NOT NULL, app TEXT NOT NULL, name TEXT NOT NULL, path TEXT NOT NULL DEFAULT '', PRIMARY KEY(device, app)) WITHOUT ROWID;
      CREATE TABLE IF NOT EXISTS remote_browser_usage(device TEXT NOT NULL, day TEXT NOT NULL, browser TEXT NOT NULL, domain TEXT NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(device, day, browser, domain)) WITHOUT ROWID;
    ''');
  }

  void loadPeers() {
    try {
      final f = File(_peersFile);
      if (!f.existsSync()) {
        peers.value = [];
        return;
      }
      final list = jsonDecode(f.readAsStringSync()) as List<dynamic>;
      peers.value = list
          .whereType<Map<String, dynamic>>()
          .map(PeerDevice.fromJson)
          .where((p) => p.id.isNotEmpty && p.token.isNotEmpty)
          .toList();
    } catch (_) {
      peers.value = [];
    }
  }

  void _savePeers(List<PeerDevice> next) {
    peers.value = next;
    try {
      Directory(dataDir()).createSync(recursive: true);
      File(_peersFile).writeAsStringSync(jsonEncode(next.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  Future<List<String>> localIpAddresses() async {
    final ips = <String>[];
    try {
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLinkLocal: false);
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && !ips.contains(addr.address)) ips.add(addr.address);
        }
      }
    } catch (_) {}
    int rank(String ip) {
      if (ip.startsWith('192.168.')) return 0;
      if (ip.startsWith('10.')) return 1;
      if (ip.startsWith('172.')) return 2;
      return 3;
    }
    ips.sort((a, b) => rank(a).compareTo(rank(b)));
    return ips;
  }

  static ({String host, int port})? parseEndpoint(String raw, {int defaultPort = kP2pPort}) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('http://')) {
      s = s.substring(7);
    } else if (s.startsWith('https://')) {
      s = s.substring(8);
    }
    final slash = s.indexOf('/');
    if (slash >= 0) s = s.substring(0, slash);
    s = s.trim();
    if (s.isEmpty) return null;

    var host = s;
    var port = defaultPort;
    if (s.startsWith('[')) {
      final end = s.indexOf(']');
      if (end <= 1) return null;
      host = s.substring(1, end).trim();
      final rest = s.substring(end + 1).trim();
      if (rest.startsWith(':')) {
        final p = int.tryParse(rest.substring(1).trim());
        if (p == null || p < 1 || p > 65535) return null;
        port = p;
      }
    } else {
      final colon = s.lastIndexOf(':');
      if (colon > 0 && s.indexOf(':') == colon) {
        final h = s.substring(0, colon).trim();
        final pStr = s.substring(colon + 1).trim();
        if (h.isEmpty) return null;
        final p = int.tryParse(pStr);
        if (p == null || p < 1 || p > 65535) return null;
        host = h;
        port = p;
      }
    }
    if (host.isEmpty) return null;
    return (host: host, port: port);
  }

  Future<void> setEnabled(bool on) async {
    try {
      final f = File(_flagFile);
      if (on) {
        Directory(dataDir()).createSync(recursive: true);
        f.writeAsStringSync('1');
        await start();
      } else {
        if (f.existsSync()) f.deleteSync();
        await stop();
      }
    } catch (_) {}
  }

  Future<void> startIfEnabled() async {
    loadPeers();
    if (enabled || peers.value.isNotEmpty) await start();
  }

  Future<void> start() async {
    loadPeers();
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, kP2pPort, shared: true);
      running.value = true;
      _server!.listen(_handleRequest, onError: (_) {});
      _autoTimer?.cancel();
      _autoTimer = Timer.periodic(const Duration(minutes: 5), (_) {
        if (peers.value.isNotEmpty) syncAll();
      });
    } catch (_) {
      running.value = false;
    }
  }

  Future<void> stop() async {
    _autoTimer?.cancel();
    _autoTimer = null;
    _pinTimer?.cancel();
    _pinTimer = null;
    activePin.value = null;
    await _server?.close(force: true);
    _server = null;
    running.value = false;
  }

  String startPinSession() {
    final rng = Random.secure();
    final pin = List.generate(6, (_) => rng.nextInt(10)).join();
    activePin.value = pin;
    _pinExpires = DateTime.now().add(const Duration(minutes: 3));
    _pinTimer?.cancel();
    _pinTimer = Timer(const Duration(minutes: 3), () {
      activePin.value = null;
    });
    return pin;
  }

  void cancelPinSession() {
    _pinTimer?.cancel();
    activePin.value = null;
  }

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/p2p/hello') {
        _replyJson(req, 200, {
          'id': deviceId,
          'name': deviceName,
          'platform': platformName,
          'version': '0.18.0',
        });
        return;
      }
      final bodyText = await utf8.decoder.bind(req).join();
      final body = bodyText.isEmpty ? <String, dynamic>{} : (jsonDecode(bodyText) as Map<String, dynamic>);

      if (req.method == 'POST' && path == '/p2p/pair') {
        final pin = (body['pin'] as String? ?? '').trim();
        final valid = activePin.value != null &&
            _pinExpires != null &&
            DateTime.now().isBefore(_pinExpires!) &&
            pin == activePin.value;
        if (!valid) {
          _replyJson(req, 403, {'error': 'invalid_pin'});
          return;
        }
        final peerId = (body['id'] as String? ?? '').trim();
        final peerName = (body['name'] as String? ?? 'Device').trim();
        final peerPlatform = (body['platform'] as String? ?? 'unknown').trim();
        final peerPort = (body['port'] as num?)?.toInt() ?? kP2pPort;
        final peerHost = req.connectionInfo?.remoteAddress.address ?? '';
        if (peerId.isEmpty || peerHost.isEmpty) {
          _replyJson(req, 400, {'error': 'bad_peer'});
          return;
        }
        final rng = Random.secure();
        final token = List.generate(16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
        final peer = PeerDevice(
          id: peerId,
          name: peerName,
          platform: peerPlatform,
          host: peerHost,
          port: peerPort,
          token: token,
          lastSync: 0,
        );
        final next = peers.value.where((p) => p.id != peerId).toList()..add(peer);
        _savePeers(next);
        _upsertDeviceRow(peer);
        cancelPinSession();
        _replyJson(req, 200, {
          'ok': true,
          'id': deviceId,
          'name': deviceName,
          'platform': platformName,
          'token': token,
        });
        return;
      }

      if (req.method == 'POST' && path == '/p2p/sync') {
        final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
        final token = auth.startsWith('Bearer ') ? auth.substring(7).trim() : '';
        PeerDevice? matched;
        for (final p in peers.value) {
          if (p.token == token && token.isNotEmpty) {
            matched = p;
            break;
          }
        }
        if (matched == null) {
          _replyJson(req, 401, {'error': 'unauthorized'});
          return;
        }
        _importSnapshot(matched.id, body, req.connectionInfo?.remoteAddress.address ?? matched.host, matched.port);
        final mine = _exportSnapshot();
        _replyJson(req, 200, mine);
        return;
      }

      _replyJson(req, 404, {'error': 'not_found'});
    } catch (_) {
      try {
        _replyJson(req, 400, {'error': 'bad_request'});
      } catch (_) {}
    }
  }

  void _replyJson(HttpRequest req, int code, Map<String, dynamic> data) {
    req.response.statusCode = code;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(data));
    req.response.close();
  }

  Future<String?> pairWithPeer(String host, String pin, {int port = kP2pPort}) async {
    await start();
    final ep = parseEndpoint(host, defaultPort: port);
    final cleanPin = pin.trim();
    if (ep == null || cleanPin.length != 6) return 'Invalid IP or PIN';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.post(ep.host, ep.port, '/p2p/pair');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'pin': cleanPin,
        'id': deviceId,
        'name': deviceName,
        'platform': platformName,
        'port': kP2pPort,
      }));
      final res = await req.close();
      final text = await utf8.decoder.bind(res).join();
      final data = jsonDecode(text) as Map<String, dynamic>;
      if (res.statusCode != 200 || data['ok'] != true) {
        return data['error'] as String? ?? 'Pairing failed';
      }
      final peer = PeerDevice(
        id: data['id'] as String,
        name: data['name'] as String? ?? ep.host,
        platform: data['platform'] as String? ?? 'unknown',
        host: ep.host,
        port: ep.port,
        token: data['token'] as String,
      );
      final next = peers.value.where((p) => p.id != peer.id).toList()..add(peer);
      _savePeers(next);
      _upsertDeviceRow(peer);
      await syncPeer(peer);
      return null;
    } catch (e) {
      return e.toString();
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> syncPeer(PeerDevice peer) async {
    final ep = parseEndpoint(peer.host, defaultPort: peer.port);
    if (ep == null) return false;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.post(ep.host, ep.port, '/p2p/sync');
      req.headers.contentType = ContentType.json;
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${peer.token}');
      req.write(jsonEncode(_exportSnapshot()));
      final res = await req.close();
      if (res.statusCode != 200) return false;
      final text = await utf8.decoder.bind(res).join();
      final data = jsonDecode(text) as Map<String, dynamic>;
      _importSnapshot(peer.id, data, ep.host, ep.port);
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<int> syncAll() async {
    var ok = 0;
    for (final p in List<PeerDevice>.of(peers.value)) {
      if (await syncPeer(p)) ok++;
    }
    return ok;
  }

  void unpair(String id) {
    _savePeers(peers.value.where((p) => p.id != id).toList());
    try {
      if (!File(dbPath()).existsSync()) return;
      final db = sqlite3.open(dbPath());
      try {
        ensureSchema(db);
        db.execute('DELETE FROM devices WHERE id = ?', [id]);
        db.execute('DELETE FROM remote_usage WHERE device = ?', [id]);
        db.execute('DELETE FROM remote_timeline WHERE device = ?', [id]);
        db.execute('DELETE FROM remote_apps WHERE device = ?', [id]);
        db.execute('DELETE FROM remote_browser_usage WHERE device = ?', [id]);
      } finally {
        db.dispose();
      }
      version.value++;
    } catch (_) {}
  }

  void _upsertDeviceRow(PeerDevice peer) {
    try {
      Directory(dataDir()).createSync(recursive: true);
      final db = sqlite3.open(dbPath());
      try {
        ensureSchema(db);
        db.execute(
          'INSERT OR REPLACE INTO devices(id, name, platform, host, port, last_sync) VALUES(?, ?, ?, ?, ?, ?)',
          [peer.id, peer.name, peer.platform, peer.host, peer.port, peer.lastSync],
        );
      } finally {
        db.dispose();
      }
      version.value++;
    } catch (_) {}
  }

  Map<String, dynamic> _exportSnapshot() {
    final since = DateTime.now().subtract(const Duration(days: 30));
    final fromDay =
        '${since.year.toString().padLeft(4, '0')}-${since.month.toString().padLeft(2, '0')}-${since.day.toString().padLeft(2, '0')}';
    final usage = <Map<String, dynamic>>[];
    final timeline = <Map<String, dynamic>>[];
    final apps = <Map<String, dynamic>>[];
    final browser = <Map<String, dynamic>>[];
    if (File(dbPath()).existsSync()) {
      final db = sqlite3.open(dbPath(), mode: OpenMode.readOnly);
      try {
        for (final r in db.select('SELECT day, app, state, ms FROM usage WHERE day >= ?', [fromDay])) {
          usage.add({'day': r['day'], 'app': r['app'], 'state': r['state'], 'ms': r['ms']});
        }
        try {
          for (final r in db.select('SELECT day, slot, app, state, ms FROM timeline WHERE day >= ?', [fromDay])) {
            timeline.add({'day': r['day'], 'slot': r['slot'], 'app': r['app'], 'state': r['state'], 'ms': r['ms']});
          }
        } catch (_) {}
        try {
          for (final r in db.select('SELECT app, name FROM apps')) {
            apps.add({'app': r['app'], 'name': r['name']});
          }
        } catch (_) {}
        try {
          for (final r in db.select('SELECT day, browser, domain, ms FROM browser_usage WHERE day >= ?', [fromDay])) {
            browser.add({'day': r['day'], 'browser': r['browser'], 'domain': r['domain'], 'ms': r['ms']});
          }
        } catch (_) {}
      } finally {
        db.dispose();
      }
    }
    return {
      'device': {'id': deviceId, 'name': deviceName, 'platform': platformName},
      'usage': usage,
      'timeline': timeline,
      'apps': apps,
      'browser_usage': browser,
    };
  }

  void _importSnapshot(String peerId, Map<String, dynamic> data, String host, int port) {
    final dev = data['device'] as Map<String, dynamic>? ?? const {};
    final name = dev['name'] as String? ?? 'Device';
    final plat = dev['platform'] as String? ?? 'unknown';
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    Directory(dataDir()).createSync(recursive: true);
    final db = sqlite3.open(dbPath());
    try {
      ensureSchema(db);
      db.execute('BEGIN');
      try {
        db.execute(
          'INSERT OR REPLACE INTO devices(id, name, platform, host, port, last_sync) VALUES(?, ?, ?, ?, ?, ?)',
          [peerId, name, plat, host, port, nowSec],
        );

        final uList = data['usage'] as List<dynamic>? ?? const [];
        if (uList.isNotEmpty) {
          final st = db.prepare('INSERT OR REPLACE INTO remote_usage(device, day, app, state, ms) VALUES(?, ?, ?, ?, ?)');
          for (final item in uList.whereType<Map<String, dynamic>>()) {
            st.execute([peerId, item['day'], item['app'], item['state'], item['ms']]);
          }
          st.dispose();
        }

        final tList = data['timeline'] as List<dynamic>? ?? const [];
        if (tList.isNotEmpty) {
          final st = db.prepare('INSERT OR REPLACE INTO remote_timeline(device, day, slot, app, state, ms) VALUES(?, ?, ?, ?, ?, ?)');
          for (final item in tList.whereType<Map<String, dynamic>>()) {
            st.execute([peerId, item['day'], item['slot'], item['app'], item['state'], item['ms']]);
          }
          st.dispose();
        }

        final aList = data['apps'] as List<dynamic>? ?? const [];
        if (aList.isNotEmpty) {
          final st = db.prepare("INSERT OR REPLACE INTO remote_apps(device, app, name, path) VALUES(?, ?, ?, '')");
          for (final item in aList.whereType<Map<String, dynamic>>()) {
            st.execute([peerId, item['app'], item['name']]);
          }
          st.dispose();
        }

        final bList = data['browser_usage'] as List<dynamic>? ?? const [];
        if (bList.isNotEmpty) {
          final st = db.prepare('INSERT OR REPLACE INTO remote_browser_usage(device, day, browser, domain, ms) VALUES(?, ?, ?, ?, ?)');
          for (final item in bList.whereType<Map<String, dynamic>>()) {
            st.execute([peerId, item['day'], item['browser'], item['domain'], item['ms']]);
          }
          st.dispose();
        }

        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
      db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      db.dispose();
    }

    final updated = [
      for (final p in peers.value)
        if (p.id == peerId)
          PeerDevice(
            id: p.id,
            name: name,
            platform: plat,
            host: host,
            port: port,
            token: p.token,
            lastSync: nowSec,
          )
        else
          p,
    ];
    _savePeers(updated);
    version.value++;
  }
}
