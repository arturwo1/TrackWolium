import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'android_collector.dart';
import 'data.dart';
import 'icons.dart';
import 'l10n.dart';
import 'prefs.dart';
import 'theme.dart';
import 'win.dart';

const _maxImage = 4 * 1024 * 1024;

Future<Uint8List?> pickImageBytes(BuildContext context, UsageBridge? bridge) async {
  Uint8List? bytes;
  if (Platform.isAndroid) {
    bytes = await bridge?.pickFile();
  } else {
    String? path;
    if (Platform.isWindows) {
      path = openFileDialog(title: tr('catPickImage'), filter: '${tr('catImages')}\u0000*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.webp\u0000');
    } else {
      path = await _askPath(context);
    }
    if (path == null || path.trim().isEmpty) return null;
    final f = File(path.trim());
    if (!f.existsSync()) return null;
    bytes = f.readAsBytesSync();
  }
  if (bytes == null || bytes.isEmpty || bytes.length > _maxImage) return null;
  return bytes;
}

Future<String?> _askPath(BuildContext context) {
  final ctl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      backgroundColor: cPanel,
      title: Text(tr('catPickImage')),
      content: TextField(controller: ctl, autofocus: true, decoration: InputDecoration(hintText: tr('catImagePath')), onSubmitted: (v) => Navigator.pop(c, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
        TextButton(onPressed: () => Navigator.pop(c, ctl.text), child: Text(tr('ok'))),
      ],
    ),
  );
}

Future<void> categoryEditor(BuildContext context, {Category? edit, UsageBridge? bridge, void Function(Category)? onCreated}) async {
  final ctl = TextEditingController(text: edit?.name ?? '');
  var color = edit?.color ?? categoryColors.first;
  var icon = edit?.icon ?? 'folder';
  Uint8List? picked;
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) {
        final preview = Category(edit?.id ?? '_new', ctl.text, color, icon, {});
        Widget swatch(int v) => GestureDetector(
              onTap: () => set(() => color = v),
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(color: Color(v), shape: BoxShape.circle, border: Border.all(color: color == v ? cPrimary : Colors.transparent, width: 2)),
              ),
            );
        Widget glyph(String id) => GestureDetector(
              onTap: () => set(() => icon = id),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: icon == id ? cPrimary : cBorder)),
                child: Icon(categoryIcons[id], size: 22, color: Color(color)),
              ),
            );
        return AlertDialog(
          backgroundColor: cPanel,
          title: Text(tr(edit == null ? 'catNew' : 'catEdit')),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  if (icon == 'img' && (picked != null || preview.hasImage))
                    ClipRRect(borderRadius: BorderRadius.circular(8), child: picked != null ? Image.memory(picked!, width: 40, height: 40, fit: BoxFit.cover) : preview.iconWidget(40))
                  else
                    Icon(categoryIcons[icon] ?? Icons.folder_outlined, size: 40, color: Color(color)),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: ctl, autofocus: true, maxLength: 40, onChanged: (_) => set(() {}), decoration: InputDecoration(labelText: tr('catName'), counterText: ''))),
                ]),
                const SizedBox(height: 14),
                Text(tr('catColor'), style: const TextStyle(color: cMuted, fontWeight: FontWeight.w700, fontSize: 12)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 8, children: [for (final v in categoryColors) swatch(v)]),
                const SizedBox(height: 14),
                Text(tr('catIcon'), style: const TextStyle(color: cMuted, fontWeight: FontWeight.w700, fontSize: 12)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 8, children: [for (final id in categoryIcons.keys) glyph(id)]),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: Text(tr('catOwnImage')),
                  onPressed: () async {
                    final b = await pickImageBytes(c, bridge);
                    if (b == null) return;
                    set(() {
                      picked = b;
                      icon = 'img';
                    });
                  },
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
            TextButton(
              onPressed: ctl.text.trim().isEmpty
                  ? null
                  : () {
                      final name = ctl.text.trim();
                      final target = edit ?? Categories.create(name, color, icon == 'img' ? 'folder' : icon);
                      target.name = name;
                      target.color = color;
                      if (picked != null) {
                        Categories.setImage(target, picked!);
                      } else if (icon != 'img' || target.hasImage) {
                        target.icon = icon;
                      }
                      Categories.save();
                      if (edit == null) onCreated?.call(target);
                      Navigator.pop(c);
                    },
              child: Text(tr('save')),
            ),
          ],
        );
      },
    ),
  );
}

class AppEntry {
  AppEntry(this.app, this.title, this.path, this.ms, this.windowed);

  final bool windowed;
  final String app;
  final String title;
  final String path;
  final int ms;
}

Future<void> categoryApps(BuildContext context, Category cat, List<AppEntry> entries) async {
  final all = List<AppEntry>.of(entries)
    ..sort((a, b) {
      final x = cat.apps.contains(a.app) ? 0 : (a.ms > 0 ? 1 : 2);
      final y = cat.apps.contains(b.app) ? 0 : (b.ms > 0 ? 1 : 2);
      if (x != y) return x.compareTo(y);
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
  final ctl = TextEditingController();
  var background = false;
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) {
        final q = ctl.text.trim().toLowerCase();
        bool real(AppEntry e) => cat.apps.contains(e.app) || (e.windowed && !Categories.isNoise(e.app, e.title));
        final pool = background ? all : [for (final e in all) if (real(e)) e];
        final shown = q.isEmpty ? pool : [for (final e in pool) if (e.title.toLowerCase().contains(q) || e.app.toLowerCase().contains(q)) e];
        return AlertDialog(
          backgroundColor: cPanel,
          title: Text('${tr('catApps')}: ${cat.name}'),
          content: SizedBox(
            width: 380,
            height: 460,
            child: Column(children: [
              TextField(
                controller: ctl,
                autofocus: true,
                onChanged: (_) => set(() {}),
                decoration: InputDecoration(isDense: true, prefixIcon: const Icon(Icons.search, size: 20), hintText: tr('search')),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: shown.isEmpty
                    ? Align(alignment: Alignment.topLeft, child: Text(tr('noData'), style: const TextStyle(color: cMuted)))
                    : ListView.builder(
                        itemCount: shown.length,
                        itemExtent: 52,
                        itemBuilder: (c, i) {
                          final e = shown[i];
                          final other = Categories.of(e.app);
                          return CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.trailing,
                            value: cat.apps.contains(e.app),
                            secondary: AppIcon(title: e.title, path: e.path, size: 28),
                            title: Text(e.title, overflow: TextOverflow.ellipsis),
                            subtitle: other != null && other != cat ? Text(other.name, style: const TextStyle(color: cMuted, fontSize: 12)) : null,
                            onChanged: (v) {
                              Categories.assign(e.app, v == true ? cat.id : null);
                              set(() {});
                            },
                          );
                        },
                      ),
              ),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: background,
                title: Text(tr('catShowBackground'), style: const TextStyle(fontSize: 13)),
                onChanged: (v) => set(() => background = v == true),
              ),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('ok')))],
        );
      },
    ),
  );
}
