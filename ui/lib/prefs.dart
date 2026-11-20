import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'data.dart';

String _path(String name) => '${dataDir()}${Platform.pathSeparator}$name';

class ViewPrefs {
  static final ValueNotifier<int> rev = ValueNotifier(0);
  static bool realFocus = false;
  static int minSec = 0;
  static bool avgLine = false;
  static bool compare = false;

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
        if (k == 'minsec') minSec = (int.tryParse(v) ?? 0).clamp(0, 3600).toInt();
        if (k == 'avg') avgLine = v == '1';
        if (k == 'compare') compare = v == '1';
      }
    } catch (_) {}
  }

  static void update({bool? real, int? sec, bool? avg, bool? cmp}) {
    realFocus = real ?? realFocus;
    minSec = sec ?? minSec;
    avgLine = avg ?? avgLine;
    compare = cmp ?? compare;
    try {
      Directory(dataDir()).createSync(recursive: true);
      File(_path('view')).writeAsStringSync('realfocus=${realFocus ? 1 : 0}\nminsec=$minSec\navg=${avgLine ? 1 : 0}\ncompare=${compare ? 1 : 0}\n');
    } catch (_) {}
    rev.value++;
  }
}

const afkChoices = [0, 60, 120, 300, 600, 900, 1800];

int readAfkSeconds() {
  try {
    final f = File(_path('afk'));
    if (!f.existsSync()) return 300;
    final v = int.tryParse(f.readAsStringSync().trim());
    if (v == null) return 300;
    return afkChoices.contains(v) ? v : 300;
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

class Categories {
  static final ValueNotifier<List<Category>> list = ValueNotifier(<Category>[]);

  static File get _file => File(_path('categories.json'));

  static void load() {
    try {
      if (!_file.existsSync()) return;
      final raw = jsonDecode(_file.readAsStringSync());
      if (raw is! List) return;
      final out = <Category>[];
      for (final e in raw) {
        if (e is! Map || e['id'] is! String || e['name'] is! String) continue;
        out.add(Category(e['id'] as String, e['name'] as String, e['color'] is int ? e['color'] as int : categoryColors.first, e['icon'] is String ? e['icon'] as String : 'folder',
            {for (final a in (e['apps'] is List ? e['apps'] as List : const [])) if (a is String) a}));
      }
      list.value = out;
    } catch (_) {}
  }

  static void save() {
    try {
      Directory(dataDir()).createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode([for (final c in list.value) c.toJson()]));
    } catch (_) {}
    list.value = List<Category>.of(list.value);
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
    save();
  }

  static void remove(String id) {
    final c = byId(id);
    if (c == null) return;
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
