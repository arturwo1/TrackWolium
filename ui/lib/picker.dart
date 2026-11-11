import 'package:flutter/material.dart';
import 'l10n.dart';
import 'theme.dart';

const cMatch = Color(0xFF4DA3FF);

class PickerItem {
  const PickerItem(this.app, this.title, this.icon);

  final String app;
  final String title;
  final Widget icon;
}

List<int>? fuzzyMatch(String query, String text) {
  if (query.isEmpty) return const [];
  final q = query.toLowerCase();
  final t = text.toLowerCase();
  final out = <int>[];
  var from = 0;
  for (var i = 0; i < q.length; i++) {
    if (q[i] == ' ') continue;
    final at = t.indexOf(q[i], from);
    if (at < 0) return null;
    out.add(at);
    from = at + 1;
  }
  return out;
}

class AppPicker extends StatelessWidget {
  const AppPicker({super.key, required this.value, required this.items, required this.onChanged, required this.current});

  final String? value;
  final List<PickerItem> items;
  final ValueChanged<String?> onChanged;
  final PickerItem? current;

  Future<void> open(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox;
    final origin = box.localToGlobal(Offset.zero);
    final rect = origin & box.size;
    final picked = await showGeneralDialog<List<String?>>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (c, _, __) => _Popup(anchor: rect, items: items, value: value),
    );
    if (picked != null) onChanged(picked.first);
  }

  @override
  Widget build(BuildContext context) {
    return HoverBox(
      onTap: () => open(context),
      builder: (hovered) => Container(
        height: 40,
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.only(left: 12, right: 6),
        decoration: BoxDecoration(
          color: hovered ? cSoft : cPanel,
          borderRadius: BorderRadius.circular(rMd),
          border: Border.fromBorderSide(line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (current != null) ...[current!.icon, const SizedBox(width: 8)],
          Flexible(child: EllipsisText(current?.title ?? tr('allApps'), style: const TextStyle(color: cPrimary, fontWeight: FontWeight.w600))),
          const Icon(Icons.arrow_drop_down, color: cMuted),
        ]),
      ),
    );
  }
}

class _Popup extends StatefulWidget {
  const _Popup({required this.anchor, required this.items, required this.value});

  final Rect anchor;
  final List<PickerItem> items;
  final String? value;

  @override
  State<_Popup> createState() => _PopupState();
}

class _PopupState extends State<_Popup> {
  final ctl = TextEditingController();
  String q = '';

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  Widget label(String text, List<int> hits, TextStyle base) {
    final set = hits.toSet();
    final spans = <TextSpan>[];
    for (var i = 0; i < text.length; i++) {
      spans.add(TextSpan(text: text[i], style: set.contains(i) ? const TextStyle(color: cMatch, fontWeight: FontWeight.w900) : null));
    }
    return Text.rich(TextSpan(style: base, children: spans), maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  Widget row(PickerItem? item, List<int> hits, bool selected) {
    return HoverBox(
      onTap: () => Navigator.pop(context, <String?>[item?.app]),
      builder: (hovered) => Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: selected ? cSoft : (hovered ? cSoft.withValues(alpha: 0.5) : Colors.transparent),
        child: Row(children: [
          if (item != null) ...[item.icon, const SizedBox(width: 8)],
          Expanded(child: label(item?.title ?? tr('allApps'), hits, const TextStyle(color: cPrimary, fontWeight: FontWeight.w600))),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final width = widget.anchor.width < 280 ? 280.0 : widget.anchor.width;
    var left = widget.anchor.left;
    if (left + width > size.width - 8) left = size.width - 8 - width;
    if (left < 8) left = 8;
    final hits = <PickerItem, List<int>>{};
    for (final it in widget.items) {
      final m = fuzzyMatch(q, it.title);
      if (m != null) hits[it] = m;
    }
    final showAll = q.isEmpty;
    final maxH = (size.height - widget.anchor.bottom - 24).clamp(160.0, 360.0).toDouble();
    return Stack(children: [
      Positioned(
        left: left,
        top: widget.anchor.bottom + 4,
        width: width,
        child: Material(
          color: cBg,
          elevation: 8,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rMd), side: line),
          clipBehavior: Clip.antiAlias,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                const Icon(Icons.search, size: 18, color: cMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: ctl,
                    autofocus: true,
                    onChanged: (v) => setState(() => q = v.trim()),
                    decoration: InputDecoration(border: InputBorder.none, isDense: true, hintText: tr('search'), hintStyle: const TextStyle(color: cMuted)),
                  ),
                ),
                if (q.isNotEmpty)
                  HoverBox(
                    onTap: () => setState(() {
                      ctl.clear();
                      q = '';
                    }),
                    builder: (h) => Icon(Icons.close, size: 18, color: h ? cPrimary : cMuted),
                  ),
              ]),
            ),
            const Divider(height: 1, color: cBorder),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxH),
              child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: [
                if (showAll) row(null, const [], widget.value == null),
                for (final e in hits.entries) row(e.key, e.value, widget.value == e.key.app),
                if (!showAll && hits.isEmpty)
                  Padding(padding: const EdgeInsets.all(14), child: Text(tr('noData'), style: const TextStyle(color: cMuted))),
              ]),
            ),
          ]),
        ),
      ),
    ]);
  }
}
