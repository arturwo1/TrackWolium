import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

const cPrimary = Color(0xFF80E0F5);
const cMuted = Color(0xFFADB0B3);
const cBg = Color(0xFF23272A);
const cBorder = Color(0xFF2B3137);
const cPanel = Color(0xEB23272A);
const cSoft = Color(0x1F80E0F5);
const cDanger = Color(0xFFF23F43);
const cWarn = Color(0xFFF0B232);
const cOk = Color(0xFF3BA55D);
const cOpen = Color(0xFF80E0F5);

const rLg = 18.0;
const rMd = 14.0;
const rSm = 12.0;

BorderSide get line => const BorderSide(color: cBorder);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: cPrimary,
    brightness: Brightness.dark,
    primary: cPrimary,
    onPrimary: cBg,
    surface: cBg,
    onSurface: cPrimary,
    error: cDanger,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: cBg,
    canvasColor: cBg,
    dividerColor: cBorder,
    dividerTheme: const DividerThemeData(color: cBorder, thickness: 1),
    fontFamily: 'Segoe UI',
    textTheme: Typography.material2021().white.apply(bodyColor: cPrimary, displayColor: cPrimary),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: cPrimary,
        foregroundColor: cBg,
        minimumSize: const Size(0, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rMd)),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: cMuted,
        minimumSize: const Size(0, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rMd)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? cBg : cMuted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? cPrimary : cBorder),
      trackOutlineColor: WidgetStateProperty.all(cBorder),
    ),
  );
}

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(16)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: cPanel,
        borderRadius: BorderRadius.circular(rLg),
        border: Border.fromBorderSide(line),
      ),
      child: child,
    );
  }
}

class HoverBox extends StatefulWidget {
  const HoverBox({super.key, required this.builder, this.onTap});

  final Widget Function(bool hovered) builder;
  final VoidCallback? onTap;

  @override
  State<HoverBox> createState() => _HoverBoxState();
}

class _HoverBoxState extends State<HoverBox> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onTap, child: widget.builder(hovered)),
    );
  }
}

class NavItem extends StatelessWidget {
  const NavItem({super.key, required this.icon, required this.label, required this.active, required this.onTap});

  final String icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HoverBox(
      onTap: onTap,
      builder: (hovered) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: hovered ? cPanel : const Color(0xC723272A),
          borderRadius: BorderRadius.circular(rMd),
          border: Border.all(color: active ? const Color(0x5980E0F5) : cBorder),
        ),
        child: Row(children: [
          Opacity(opacity: 0.85, child: SvgPicture.asset('assets/icons/$icon.svg', width: 18, height: 18)),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

class SelectBox<T> extends StatelessWidget {
  const SelectBox({super.key, required this.value, required this.items, required this.onChanged});

  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: cPanel,
        borderRadius: BorderRadius.circular(rMd),
        border: Border.fromBorderSide(line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          items: items,
          onChanged: onChanged,
          dropdownColor: cBg,
          borderRadius: BorderRadius.circular(rMd),
          iconEnabledColor: cMuted,
          style: const TextStyle(color: cPrimary, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class EllipsisText extends StatelessWidget {
  const EllipsisText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final effective = DefaultTextStyle.of(context).style.merge(style);
      final tp = TextPainter(text: TextSpan(text: text, style: effective), maxLines: 1, textDirection: TextDirection.ltr)
        ..layout(maxWidth: c.maxWidth.isFinite ? c.maxWidth : double.infinity);
      final w = Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
      if (!tp.didExceedMaxLines) return w;
      return Tooltip(message: text, waitDuration: const Duration(milliseconds: 250), child: w);
    });
  }
}
