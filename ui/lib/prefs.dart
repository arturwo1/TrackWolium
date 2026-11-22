import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'data.dart';
import 'l10n.dart';

String _path(String name) => '${dataDir()}${Platform.pathSeparator}$name';

class ViewPrefs {
  static final ValueNotifier<int> rev = ValueNotifier(0);
  static bool realFocus = false;
  static int minSec = 0;
  static int maxSec = 0;
  static bool avgLine = false;
  static bool compare = false;
  static String androidControls = 'gestures';

  static void load() {
    try {
      final f = File(_path('view'));
      if (!f.existsSync()) return;
      for (final line in f.readAsLinesSync()) {
        final i = line.indexOf('=');
        if (i < 0) continue;
        final k = line.substring(0, i).trim();
        final v = line.substring(i + 1).trim();
        if (k == 'realfocus') realFocus = v == '1';
        if (k == 'minsec') minSec = (int.tryParse(v) ?? 0).clamp(0, maxDuration).toInt();
        if (k == 'maxsec') maxSec = (int.tryParse(v) ?? 0).clamp(0, maxDuration).toInt();
        if (k == 'avg') avgLine = v == '1';
        if (k == 'compare') compare = v == '1';
        if (k == 'controls' && (v == 'gestures' || v == 'buttons')) androidControls = v;
      }
    } catch (_) {}
  }

  static void update({bool? real, int? sec, int? max, bool? avg, bool? cmp, String? controls}) {
    realFocus = real ?? realFocus;
    minSec = sec ?? minSec;
    maxSec = max ?? maxSec;
    avgLine = avg ?? avgLine;
    compare = cmp ?? compare;
    if (controls == 'gestures' || controls == 'buttons') androidControls = controls!;
    try {
      Directory(dataDir()).createSync(recursive: true);
      File(_path('view')).writeAsStringSync(
        'realfocus=${realFocus ? 1 : 0}\nminsec=$minSec\nmaxsec=$maxSec\navg=${avgLine ? 1 : 0}\ncompare=${compare ? 1 : 0}\ncontrols=$androidControls\n',
      );
    } catch (_) {}
    rev.value++;
  }
}

const maxDuration = 30 * 86400;

int? parseDuration(String text) {
  final t = text.trim().toLowerCase();
  if (t.isEmpty) return null;
  final re = RegExp(r'(\d+(?:[.,]\d+)?)\s*([a-zа-яё]*)');
  var pos = 0;
  var total = 0.0;
  var any = false;
  for (final m in re.allMatches(t)) {
    if (t.substring(pos, m.start).trim().isNotEmpty) return null;
    pos = m.end;
    final n = double.tryParse(m[1]!.replaceAll(',', '.'));
    if (n == null) return null;
    final u = m[2]!;
    double mult;
    if (u.isEmpty || u == 's' || u == 'sec' || u == 'с' || u == 'сек') {
      mult = 1;
    } else if (u == 'm' || u == 'min' || u == 'м' || u == 'мин') {
      mult = 60;
    } else if (u == 'h' || u == 'hr' || u == 'ч' || u == 'час') {
      mult = 3600;
    } else if (u == 'd' || u == 'day' || u == 'д' || u == 'дн') {
      mult = 86400;
    } else {
      return null;
    }
    total += n * mult;
    any = true;
  }
  if (!any || t.substring(pos).trim().isNotEmpty) return null;
  return math.min(total.round(), maxDuration);
}

String durationText(int seconds) {
  if (seconds <= 0) return '0';
  final h = seconds ~/ 3600;
  final m = seconds % 3600 ~/ 60;
  final s = seconds % 60;
  return [if (h > 0) '$h${tr('unitH')}', if (m > 0) '$m${tr('unitM')}', if (s > 0) '$s${tr('unitS')}'].join(' ');
}

int readAfkSeconds() {
  try {
    final f = File(_path('afk'));
    if (!f.existsSync()) return 300;
    final v = int.tryParse(f.readAsStringSync().trim());
    if (v == null) return 300;
    return v == 0 ? 0 : v.clamp(30, 3600).toInt();
  } catch (_) {
    return 300;
  }
}

void writeAfkSeconds(int seconds) {
  try {
    Directory(dataDir()).createSync(recursive: true);
    File(_path('afk')).writeAsStringSync('$seconds\n');
  } catch (_) {}
}

const categoryIcons = <String, IconData>{
  'folder': Icons.folder_outlined,
  'work': Icons.work_outline,
  'games': Icons.sports_esports_outlined,
  'web': Icons.language,
  'chat': Icons.chat_bubble_outline,
  'video': Icons.movie_outlined,
  'music': Icons.music_note,
  'code': Icons.code,
  'study': Icons.school_outlined,
  'tools': Icons.build_outlined,
  'social': Icons.groups_outlined,
  'shop': Icons.shopping_cart_outlined,
};

const categoryColors = <int>[0xFF5865F2, 0xFF3BA55D, 0xFFF0B232, 0xFFED4245, 0xFFEB459E, 0xFF00A8FC, 0xFFFF7A45, 0xFF9B84EE, 0xFF2DD4BF, 0xFF8E9297];

class Category {
  Category(this.id, this.name, this.color, this.icon, this.apps);

  final String id;
  String name;
  int color;
  String icon;
  Set<String> apps;

  Color get tint => Color(color);

  File get image => File(_path('catimg${Platform.pathSeparator}$id'));

  bool get hasImage => icon == 'img' && image.existsSync();

  Widget iconWidget(double size) {
    if (hasImage) {
      return ClipRRect(borderRadius: BorderRadius.circular(size / 5), child: Image.file(image, width: size, height: size, fit: BoxFit.cover, cacheWidth: (size * 3).round(), errorBuilder: (c, e, s) => Icon(Icons.folder_outlined, size: size, color: tint)));
    }
    return Icon(categoryIcons[icon] ?? Icons.folder_outlined, size: size, color: tint);
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'color': color, 'icon': icon, 'apps': apps.toList()..sort()};
}

class _Default {
  const _Default(this.id, this.key, this.color, this.icon, this.names, this.parts, this.aliases);

  final List<String> aliases;
  final String id;
  final String key;
  final int color;
  final String icon;
  final Set<String> names;
  final List<String> parts;
}

const _defaults = <_Default>[
  _Default('def_games', 'catDefGames', 0xFFED4245, 'games', {
    'steam', 'epicgameslauncher', 'battle.net', 'battlenet', 'riotclientservices', 'riotclientux', 'valorant', 'leagueclient', 'league of legends', 'minecraft', 'minecraftlauncher', 'robloxplayerbeta', 'robloxstudiobeta', 'rocketleague', 'csgo', 'cs2', 'dota2', 'gta5', 'eldenring', 'genshinimpact', 'yuanshen', 'overwatch', 'r5apex', 'pubg', 'tslgame', 'hearthstone', 'wow', 'galaxyclient', 'eadesktop', 'origin', 'upc', 'ubisoftconnect', 'osu!', 'factorio', 'terraria', 'stardew valley', 'hollow knight', 'fallguys_client', 'cyberpunk2077', 'witcher3', 'starfield', 'baldursgate3', 'bg3', 'helldivers2', 'palworld-win64-shipping', 'com.mojang.minecraftpe', 'com.roblox.client', 'com.supercell.clashofclans', 'com.supercell.brawlstars', 'com.supercell.clashroyale', 'com.tencent.ig', 'com.activision.callofduty.shooter', 'com.miHoYo.GenshinImpact', 'com.mobile.legends', 'com.miniclip.eightballpool', 'com.prineside.tdi2', 'org.lichess.mobileapp', 'com.asantee.magicrampage', 'com.geewa.smashingfour', 'jp.co.ponos.battlecatsen', 'jp.co.ponos.battlecats',
  }, ['shipping', 'minecraft', 'roblox', 'eightballpool', 'brawlstars', 'clashroyale', 'clashofclans', 'amongus', 'subwaysurf', 'infinitode', 'lichess', 'magicrampage', 'smashingfour', 'battlecats'], ['games', 'game', 'игры', 'игра']),
  _Default('def_browsers', 'catDefBrowsers', 0xFF00A8FC, 'web', {
    'chrome', 'msedge', 'firefox', 'opera', 'opera_gx', 'brave', 'vivaldi', 'iexplore', 'arc', 'browser', 'yandex', 'safari', 'chromium', 'chromium-browser', 'librewolf', 'waterfox', 'tor', 'zen', 'duckduckgo', 'google-chrome', 'microsoft-edge', 'firefox-esr', 'com.android.chrome', 'org.mozilla.firefox', 'org.mozilla.fenix', 'com.brave.browser', 'com.opera.browser', 'com.opera.gx', 'com.microsoft.emmx', 'com.sec.android.app.sbrowser', 'com.vivaldi.browser', 'com.duckduckgo.mobile.android', 'com.yandex.browser', 'org.chromium.chrome', 'com.kiwibrowser.browser',
  }, ['chrome', 'opera', 'firefox', 'mozilla', 'sbrowser', 'vivaldi'], ['browsers', 'browser', 'браузеры', 'браузер']),
  _Default('def_dev', 'catDefDev', 0xFF3BA55D, 'code', {
    'code', 'code - insiders', 'devenv', 'idea64', 'idea', 'pycharm64', 'pycharm', 'webstorm64', 'webstorm', 'clion64', 'clion', 'rider64', 'rider', 'studio64', 'goland64', 'goland', 'rubymine64', 'phpstorm64', 'datagrip64', 'cursor', 'windsurf', 'sublime_text', 'notepad++', 'vim', 'nvim', 'emacs', 'gitkraken', 'githubdesktop', 'windowsterminal', 'wt', 'cmd', 'powershell', 'pwsh', 'putty', 'docker desktop', 'postman', 'zed', 'kate', 'gedit', 'konsole', 'gnome-terminal', 'alacritty', 'kitty', 'wezterm', 'xterm', 'flutter', 'dart', 'node', 'python', 'python3', 'git', 'sourcetree', 'insomnia', 'dbeaver', 'heidisql', 'termux', 'com.termux', 'com.termux.api', 'com.github.android', 'com.android.tools.build', 'com.microsoft.vscode', 'com.foxdebug.acode', 'com.foxdebug.acodefree', 'ru.iiec.pydroid3', 'com.termoneplus', 'org.connectbot', 'com.sonelli.juicessh', 'com.server.auditor.ssh.client', 'org.gnu.emacs', 'com.jetbrains.fleet',
  }, ['termux', 'githubdesktop', 'vscode', 'acode', 'pydroid', 'ssh'], ['development', 'dev', 'разработка']),
  _Default('def_chat', 'catDefChat', 0xFF5865F2, 'chat', {
    'discord', 'discordptb', 'discordcanary', 'telegram', 'whatsapp', 'slack', 'teams', 'ms-teams', 'skype', 'zoom', 'viber', 'signal', 'element', 'thunderbird', 'outlook', 'olk', 'vk', 'max', 'org.telegram.messenger', 'org.telegram.messenger.web', 'org.thunderdog.challegram', 'com.whatsapp', 'com.discord', 'com.viber.voip', 'org.thoughtcrime.securesms', 'com.vkontakte.android', 'com.facebook.orca', 'com.skype.raider', 'com.slack', 'us.zoom.videomeetings', 'com.microsoft.teams', 'com.google.android.gm', 'com.google.android.apps.messaging', 'com.samsung.android.messaging',
  }, ['telegram', 'discord', 'aliucord', 'whatsapp', 'viber', 'skype'], ['communication', 'chat', 'chats', 'общение', 'чаты', 'мессенджеры']),
  _Default('def_media', 'catDefMedia', 0xFFEB459E, 'music', {
    'spotify', 'vlc', 'mpv', 'potplayermini64', 'potplayermini', 'wmplayer', 'itunes', 'music.ui', 'yandexmusic', 'foobar2000', 'aimp', 'musicbee', 'obs64', 'obs', 'netflix', 'kodi', 'plex', 'tidal', 'mpc-hc64', 'mpc-hc', 'mpc-be64', 'groove', 'video.ui', 'com.google.android.youtube', 'com.google.android.apps.youtube.music', 'com.spotify.music', 'org.videolan.vlc', 'com.netflix.mediaclient', 'ru.yandex.music', 'com.zhiliaoapp.musically', 'tv.twitch.android.app', 'com.amazon.avod.thirdpartyclient', 'com.google.android.apps.photos',
  }, ['youtube', 'spotify', 'netflix', 'twitch', 'soundcloud'], ['media', 'медиа']),
];

class Categories {
  static final ValueNotifier<List<Category>> list = ValueNotifier(<Category>[]);
  static final Set<String> seeded = {};
  static final Set<String> decided = {};
  static final Map<String, String> links = {};
  static const rulesVersion = 5;

  static File get _file => File(_path('categories.json'));

  static void load() {
    try {
      if (_file.existsSync()) {
        final raw = jsonDecode(_file.readAsStringSync());
        final items = raw is List ? raw : (raw is Map && raw['categories'] is List ? raw['categories'] as List : const []);
        if (raw is Map) {
          for (final k in (raw['seeded'] is List ? raw['seeded'] as List : const [])) {
            if (k is String) seeded.add(k);
          }
          for (final k in (raw['decided'] is List ? raw['decided'] as List : const [])) {
            if (k is String) decided.add(k);
          }
          if (raw['links'] is Map) {
            (raw['links'] as Map).forEach((k, v) {
              if (k is String && v is String) links[k] = v;
            });
          }
        }
        final purge = raw is Map ? raw['rules'] != rulesVersion : false;
        if (raw is List) {
          for (final e in raw) {
            if (e is Map && e['apps'] is List) decided.addAll((e['apps'] as List).whereType<String>());
          }
        }
        final out = <Category>[];
        for (final e in items) {
          if (e is! Map || e['id'] is! String || e['name'] is! String) continue;
          out.add(Category(e['id'] as String, e['name'] as String, e['color'] is int ? e['color'] as int : categoryColors.first, e['icon'] is String ? e['icon'] as String : 'folder',
              {for (final a in (e['apps'] is List ? e['apps'] as List : const []) as List) if (a is String) a}));
        }
        if (purge) {
          for (final c in out) {
            c.apps.removeWhere((a) => !decided.contains(a));
          }
        }
        for (final c in out) {
          if (c.id == 'def_dev' && !decided.contains('io.github.arturwo1.wolium')) {
            c.apps.remove('io.github.arturwo1.wolium');
          }
        }
        list.value = out;
        if (purge) save(notify: false);
      }
    } catch (_) {}
    seed();
  }

  static bool _named(Category c, _Default d) {
    final n = c.name.trim().toLowerCase();
    return n == tr(d.key).toLowerCase() || d.aliases.contains(n);
  }

  static void seed() {
    var changed = false;
    final next = List<Category>.of(list.value);
    for (final d in _defaults) {
      final mine = next.where((c) => c.id == d.id).toList();
      final other = next.where((c) => c.id != d.id && !c.id.startsWith('def_') && _named(c, d)).toList();
      if (mine.isNotEmpty && other.isNotEmpty) {
        other.first.apps.addAll(mine.first.apps);
        next.removeWhere((c) => c.id == d.id);
        links[d.id] = other.first.id;
        changed = true;
        continue;
      }
      if (seeded.contains(d.id) || mine.isNotEmpty) continue;
      seeded.add(d.id);
      if (other.isNotEmpty) {
        links[d.id] = other.first.id;
      } else {
        next.add(Category(d.id, tr(d.key), d.color, d.icon, <String>{}));
      }
      changed = true;
    }
    list.value = next;
    if (changed || seeded.length != _defaults.length) save(notify: false);
  }

  static void save({bool notify = true}) {
    try {
      Directory(dataDir()).createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode({'v': 2, 'rules': rulesVersion, 'seeded': seeded.toList()..sort(), 'decided': decided.toList()..sort(), 'links': links, 'categories': [for (final c in list.value) c.toJson()]}));
    } catch (_) {}
    LimitPrefs.writeCore();
    if (notify) list.value = List<Category>.of(list.value);
  }

  static const _gamePaths = ['/steamapps/', '/epic games/', '/riot games/', '/gog games/', '/gog galaxy/games/', '/ubisoft/', '/ea games/', '/origin games/', '/xboxgames/', '/roblox/', '/battle.net/', '/heroic/', '/lutris/'];

  static Set<String> _tokens(String text) => text.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((e) => e.isNotEmpty).toSet();

  static const _noise = {'updater', 'update', 'updates', 'helper', 'crash', 'crashreporter', 'crashpad', 'reporter', 'service', 'services', 'bootstrapper', 'bootstrap', 'redist', 'redistributable', 'setup', 'installer', 'install', 'uninstall', 'uninst', 'sfx', 'splash'};

  static bool isNoise(String app, [String title = '']) => _tokens('$app $title').any(_noise.contains);

  static const _gamePrefixes = [
    'com.miniclip.', 'com.supercell.', 'com.rovio.', 'com.kiloo.', 'com.halfbrick.',
    'com.king.', 'com.mojang.', 'com.innersloth.', 'com.ea.game.', 'com.gameloft.',
    'com.playrix.', 'com.zynga.', 'com.nianticlabs.', 'jp.co.ponos.', 'com.prineside.',
  ];

  static String? _defaultFor(String app, String path, int sys, [String title = '']) {
    var n = app.toLowerCase();
    if (n.endsWith('.exe')) n = n.substring(0, n.length - 4);
    if (n == 'io.github.arturwo1.wolium' || n == 'wolium' || n == 'trackwolium') return null;
    final p = path.toLowerCase().replaceAll('\\', '/');
    if (p.isNotEmpty && !p.contains('/icons/') && _gamePaths.any(p.contains)) return 'def_games';
    if (_gamePrefixes.any(n.startsWith)) return 'def_games';
    for (final d in _defaults) {
      if (d.names.any((x) => x.toLowerCase() == n)) return d.id;
    }
    final t = title.trim().toLowerCase();
    if (n == 'com.github.android' || t == 'github' || t == 'github desktop') return 'def_dev';
    final pkgText = n.startsWith('io.github.') ? n.substring('io.github.'.length) : n;
    final tokens = _tokens('$pkgText $t');
    for (final d in _defaults) {
      if (d.parts.any(tokens.contains)) return d.id;
    }
    switch (sys) {
      case 0:
        return 'def_games';
      case 1:
      case 2:
        return 'def_media';
      case 4:
        return 'def_chat';
    }
    return null;
  }

  static bool autoAssign(Map<String, String> paths, {Map<String, int> sys = const {}, Map<String, String> titles = const {}, Set<String>? windowed}) {
    var changed = false;
    for (final e in paths.entries) {
      final app = e.key;
      if (app.toLowerCase() == 'io.github.arturwo1.wolium') continue;
      if (decided.contains(app) || of(app) != null) continue;
      if (windowed != null && !windowed.contains(app)) continue;
      final title = titles[app] ?? '';
      if (isNoise(app, title)) continue;
      final id = _defaultFor(app, e.value, sys[app] ?? -1, title);
      final cat = byId(id == null ? null : (links[id] ?? id));
      if (cat == null) continue;
      cat.apps.add(app);
      changed = true;
    }
    if (changed) save(notify: false);
    return changed;
  }

  static Category? byId(String? id) {
    if (id == null) return null;
    for (final c in list.value) {
      if (c.id == id) return c;
    }
    return null;
  }

  static Category? of(String app) {
    for (final c in list.value) {
      if (c.apps.contains(app)) return c;
    }
    return null;
  }

  static Category create(String name, int color, String icon) {
    final c = Category(DateTime.now().microsecondsSinceEpoch.toRadixString(36), name, color, icon, <String>{});
    list.value = [...list.value, c];
    save();
    return c;
  }

  static void assign(String app, String? id) {
    for (final c in list.value) {
      c.apps.remove(app);
    }
    byId(id)?.apps.add(app);
    decided.add(app);
    save();
  }

  static void remove(String id) {
    final c = byId(id);
    if (c == null) return;
    decided.addAll(c.apps);
    try {
      if (c.image.existsSync()) c.image.deleteSync();
    } catch (_) {}
    list.value = [for (final x in list.value) if (x.id != id) x];
    save();
  }

  static void setImage(Category c, Uint8List bytes) {
    try {
      Directory(_path('catimg')).createSync(recursive: true);
      c.image.writeAsBytesSync(bytes);
      imageCache.clear();
      imageCache.clearLiveImages();
      c.icon = 'img';
      save();
    } catch (_) {}
  }
}

class DayLimit {
  DayLimit(this.kind, this.id, this.name, this.seconds);

  final String kind;
  final String id;
  String name;
  int seconds;

  Map<String, dynamic> toJson() => {'kind': kind, 'id': id, 'name': name, 'seconds': seconds};
}

class LimitPrefs {
  static final ValueNotifier<List<DayLimit>> list = ValueNotifier(<DayLimit>[]);

  static File get _file => File(_path('limits.json'));

  static void load() {
    try {
      if (!_file.existsSync()) return;
      final raw = jsonDecode(_file.readAsStringSync());
      if (raw is! List) return;
      final out = <DayLimit>[];
      for (final e in raw) {
        if (e is! Map || e['kind'] is! String || e['id'] is! String || e['seconds'] is! int) continue;
        out.add(DayLimit(e['kind'] as String, e['id'] as String, e['name'] is String ? e['name'] as String : e['id'] as String, e['seconds'] as int));
      }
      list.value = out;
    } catch (_) {}
    writeCore();
  }

  static void set(String kind, String id, String name, int seconds) {
    final next = [for (final l in list.value) if (!(l.kind == kind && l.id == id)) l];
    if (seconds >= 60) next.add(DayLimit(kind, id, name, seconds));
    list.value = next;
    save();
  }

  static DayLimit? forTarget(String kind, String id) {
    for (final l in list.value) {
      if (l.kind == kind && l.id == id) return l;
    }
    return null;
  }

  static void remove(DayLimit l) {
    list.value = [for (final x in list.value) if (x != l) x];
    save();
  }

  static void save() {
    try {
      Directory(dataDir()).createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode([for (final l in list.value) l.toJson()]));
    } catch (_) {}
    writeCore();
  }

  static void writeCore() {
    try {
      final lines = StringBuffer();
      for (final l in list.value) {
        String name = l.name;
        Iterable<String> apps;
        if (l.kind == 'cat') {
          final c = Categories.byId(l.id);
          if (c == null) continue;
          name = c.name;
          apps = c.apps;
        } else {
          apps = [l.id];
        }
        if (apps.isEmpty) continue;
        final title = tr('limitTitle');
        final body = tr('limitBody').replaceAll('{name}', name).replaceAll('{limit}', durationText(l.seconds));
        String clean(String v) => v.replaceAll(RegExp(r'[\t\r\n\x1f]'), ' ');
        lines.writeln([l.seconds, clean('${l.kind}:${l.id}'), apps.map(clean).join('\x1f'), clean(title), clean(body)].join('\t'));
      }
      Directory(dataDir()).createSync(recursive: true);
      final f = File(_path('limits'));
      final text = lines.toString();
      if (text.isEmpty) {
        if (f.existsSync()) f.deleteSync();
      } else {
        f.writeAsStringSync(text);
      }
    } catch (_) {}
  }
}
