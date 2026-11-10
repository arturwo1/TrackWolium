import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';
import 'chart.dart';
import 'data.dart';
import 'icons.dart';
import 'l10n.dart';
import 'mark.dart';
import 'theme.dart';
import 'win.dart';

const appName = 'Wolium';
const siteUrl = 'https://wolium.netlify.app/';
const privacyUrl = 'https://wolium.netlify.app/privacy-policy/';
const narrowWidth = 760.0;
const staleSeconds = 7;

void main() {
  if (!claimSingleInstance()) exit(0);
  migrateLegacyData();
  loadLanguage();
  runApp(const WoliumApp());
}

class WoliumApp extends StatelessWidget {
  const WoliumApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: language,
      builder: (context, _, __) => MaterialApp(
        title: appName,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const Root(),
      ),
    );
  }
}

Future<void> open(String url) => launchUrl(Uri.parse(url));

class Root extends StatefulWidget {
  const Root({super.key});

  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  final settings = Settings.load();
  late bool accepted = settings.accepted;

  @override
  void initState() {
    super.initState();
    if (accepted) startService();
  }

  void accept() {
    settings.accepted = true;
    startService();
    setState(() => accepted = true);
  }

  void withdraw() {
    settings.accepted = false;
    setState(() => accepted = false);
  }

  @override
  Widget build(BuildContext context) {
    if (accepted) return Shell(onWithdraw: withdraw);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Panel(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Brand(),
                  const SizedBox(height: 16),
                  Text(tr('welcome'), style: const TextStyle(height: 1.5)),
                  const SizedBox(height: 8),
                  TextButton(onPressed: () => open(privacyUrl), child: Text(tr('privacy'))),
                  const SizedBox(height: 8),
                  Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    FilledButton(onPressed: accept, child: Text(tr('accept'))),
                    LanguagePicker(onChanged: () => setState(() {})),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class Brand extends StatelessWidget {
  const Brand({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 38,
        height: 38,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(rSm),
          border: Border.fromBorderSide(line),
          color: cSoft,
        ),
        child: const WoliumMark(size: 30),
      ),
      const SizedBox(width: 10),
      Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text(appName, style: TextStyle(fontWeight: FontWeight.w800, height: 1.1)),
        Text(tr('brandSub'), style: const TextStyle(fontSize: 12, color: cMuted, height: 1.1)),
      ]),
    ]);
  }
}

class LanguagePicker extends StatelessWidget {
  const LanguagePicker({super.key, this.onChanged});

  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    return SelectBox<String>(
      value: language.value,
      items: [for (final e in languages.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
      onChanged: (v) {
        if (v == null) return;
        saveLanguage(v);
        onChanged?.call();
      },
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key, required this.onWithdraw});

  final VoidCallback onWithdraw;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final usage = Usage();
  Timer? timer;
  int tab = 0;
  List<String> days = [];
  String? day;
  List<AppUsage> rows = [];
  Duration? beat;
  bool hasDb = false;
  DateTime? startedAt = DateTime.now();
  int ticks = 0;
  bool isPaused = false;
  bool liveMode = false;
  List<Slot> slots = [];
  String? slotsFor;
  String? only;
  Map<String, AppMeta> names = {};
  Metric metric = Metric.focused;

  @override
  void initState() {
    super.initState();
    requestFlush();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (++ticks % 20 == 0) requestFlush();
      refresh();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    usage.close();
    super.dispose();
  }

  String todayKey() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${two(n.month)}-${two(n.day)}';
  }

  void refresh() {
    final d = usage.days();
    final today = todayKey();
    if (!d.contains(today)) d.insert(0, today);
    final selected = day != null && d.contains(day) ? day : d.first;
    final b = usage.sinceHeartbeat();
    final up = b != null && b <= const Duration(seconds: staleSeconds);
    final l = up && selected == today ? usage.live() : null;
    setState(() {
      hasDb = usage.available;
      days = d;
      day = selected;
      beat = b;
      isPaused = usage.paused;
      liveMode = l != null;
      rows = l ?? usage.day(selected!);
      if (slotsFor != selected || ticks % 5 == 0) {
        slots = usage.timeline(selected!);
        names = usage.names();
        slotsFor = selected;
      }
    });
  }

  bool get serviceDown {
    final grace = startedAt != null && DateTime.now().difference(startedAt!) < const Duration(seconds: 10);
    if (beat == null) return !grace;
    return beat! > const Duration(seconds: staleSeconds);
  }

  Widget banner() {
    return Container(
      width: double.infinity,
      color: cDanger.withValues(alpha: 0.16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(tr('serviceDown'), style: const TextStyle(color: cDanger, fontWeight: FontWeight.w700)),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: cDanger, foregroundColor: Colors.white, minimumSize: const Size(0, 34)),
          onPressed: () {
            startService();
            setState(() => startedAt = DateTime.now());
          },
          child: Text(tr('restart')),
        ),
      ]),
    );
  }

  Widget pausedBanner() {
    return Container(
      width: double.infinity,
      color: cWarn.withValues(alpha: 0.16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(tr('pausedBanner'), style: const TextStyle(color: cWarn, fontWeight: FontWeight.w700)),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: cWarn, foregroundColor: cBg, minimumSize: const Size(0, 34)),
          onPressed: () {
            usage.setPaused(false);
            refresh();
          },
          child: Text(tr('resume')),
        ),
      ]),
    );
  }

  Widget statusChip() {
    final down = serviceDown;
    final color = down ? cDanger : (isPaused ? cWarn : cOk);
    final text = down ? tr('statusOff') : (isPaused ? tr('statusPaused') : tr('statusOn'));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 8),
      Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w800)),
    ]);
  }

  Color stateColor(int? s) {
    switch (s) {
      case 0:
        return cOk;
      case 1:
        return cOpen;
      case 2:
        return cWarn;
      default:
        return cMuted;
    }
  }

  String stateText(int? s) {
    switch (s) {
      case 0:
        return tr('focused');
      case 1:
        return tr('open');
      case 2:
        return tr('minimized');
      case 3:
        return tr('background');
      default:
        return tr('idle');
    }
  }

  Widget nowCell(AppUsage r) {
    final c = r.now == null ? cMuted.withValues(alpha: 0.6) : stateColor(r.now);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Flexible(child: Text(r.now == null ? '-' : stateText(r.now), style: TextStyle(color: c, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }

  String titleOf(String app) {
    final n = names[app]?.name;
    return n != null && n.isNotEmpty ? n : prettyApp(app);
  }

  Widget iconOf(String app, double size) => AppIcon(title: titleOf(app), path: names[app]?.path ?? '', size: size);

  int metricValue(AppUsage r) => metricOf(r.ms, metric);

  List<AppUsage> sortedRows() {
    final list = List<AppUsage>.from(rows);
    list.sort((a, b) {
      final c = metricValue(b).compareTo(metricValue(a));
      return c != 0 ? c : b.total.compareTo(a.total);
    });
    return list;
  }

  void toggleOnly(String app) {
    setState(() => only = only == app ? null : app);
  }

  Widget chartPanel(bool narrow) {
    return Panel(
      padding: EdgeInsets.all(narrow ? 12 : 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(tr('chartTitle'), style: const TextStyle(fontWeight: FontWeight.w800)),
          SelectBox<Metric>(
            value: metric,
            items: [for (final m in Metric.values) DropdownMenuItem(value: m, child: Text(metricLabel(m)))],
            onChanged: (v) => setState(() => metric = v ?? metric),
          ),
          if (only != null)
            InkWell(
              onTap: () => setState(() => only = null),
              borderRadius: BorderRadius.circular(rSm),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: cSoft, borderRadius: BorderRadius.circular(rSm), border: Border.fromBorderSide(line)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(titleOf(only!), style: const TextStyle(color: cPrimary, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 6),
                  const Icon(Icons.close, size: 14, color: cPrimary),
                ]),
              ),
            ),
        ]),
        const SizedBox(height: 10),
        ActivityChart(slots: slots, only: only, metric: metric, title: titleOf, icon: iconOf, height: narrow ? 190 : 240),
      ]),
    );
  }

  Widget dateRow(TextStyle head) {
    return Row(children: [
      Text(tr('date'), style: head),
      const SizedBox(width: 12),
      SelectBox<String>(
        value: day,
        items: [for (final d in days) DropdownMenuItem(value: d, child: Text(d))],
        onChanged: (v) {
          day = v;
          requestFlush();
          refresh();
        },
      ),
    ]);
  }

  Widget wideTable(TextStyle head) {
    Widget cell(String t, {TextStyle? style, bool ellipsis = false}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
          child: Text(t, style: style, overflow: ellipsis ? TextOverflow.ellipsis : null),
        );
    return Table(
      columnWidths: const {0: FlexColumnWidth(3)},
      children: [
        TableRow(children: [
          cell(tr('app'), style: head),
          if (liveMode) cell(tr('now'), style: head),
          cell(tr('focused'), style: head),
          cell(tr('open'), style: head),
          cell(tr('minimized'), style: head),
          cell(tr('background'), style: head),
          cell(tr('total'), style: head),
        ]),
        for (final r in sortedRows())
          TableRow(
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: cBorder))),
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => toggleOnly(r.app),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                    child: Row(children: [
                      AppIcon(title: r.title, path: r.path, size: 22),
                      const SizedBox(width: 8),
                      Expanded(child: Text(r.title, style: TextStyle(fontWeight: FontWeight.w700, color: only == r.app ? cPrimary : null), overflow: TextOverflow.ellipsis)),
                    ]),
                  ),
                ),
              ),
              if (liveMode) nowCell(r),
              for (final i in [0, 1, 2, 3]) cell(r.ms[i] == 0 ? '-' : formatMs(r.ms[i])),
              cell(formatMs(r.total), style: const TextStyle(fontWeight: FontWeight.w800)),
            ],
          ),
      ],
    );
  }

  Widget compactList(TextStyle head) {
    Widget stat(String label, int ms) => Padding(
          padding: const EdgeInsets.only(right: 14, top: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(color: cMuted, fontSize: 12)),
            Text(ms == 0 ? '-' : formatMs(ms), style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
        );
    return Column(children: [
      for (final r in sortedRows())
        GestureDetector(
          onTap: () => toggleOnly(r.app),
          child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(rMd),
            border: Border.all(color: only == r.app ? cPrimary : cBorder),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (liveMode) ...[
                Container(width: 8, height: 8, decoration: BoxDecoration(color: r.now == null ? cMuted : stateColor(r.now), shape: BoxShape.circle)),
                const SizedBox(width: 8),
              ],
              AppIcon(title: r.title, path: r.path, size: 22),
              const SizedBox(width: 8),
              Expanded(child: Text(r.title, style: const TextStyle(fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis)),
              Text(formatMs(r.total), style: const TextStyle(fontWeight: FontWeight.w900)),
            ]),
            Wrap(children: [
              stat(tr('focused'), r.ms[0]),
              stat(tr('open'), r.ms[1]),
              stat(tr('minimized'), r.ms[2]),
              stat(tr('background'), r.ms[3]),
            ]),
          ]),
        ),
        ),
    ]);
  }

  Widget activity(bool narrow) {
    const head = TextStyle(color: cMuted, fontWeight: FontWeight.w800);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      chartPanel(narrow),
      const SizedBox(height: 12),
      if (rows.isEmpty)
        Panel(child: Text(tr('noData')))
      else
        Panel(
          padding: EdgeInsets.all(narrow ? 12 : 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            dateRow(head),
            const SizedBox(height: 8),
            narrow ? compactList(head) : wideTable(head),
          ]),
        ),
    ]);
  }

  Widget topbar(bool narrow) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(color: cPanel, border: Border(bottom: BorderSide(color: cBorder))),
      child: Row(children: [
        if (narrow) const Brand(),
        const Spacer(),
        TextButton(onPressed: () => open(siteUrl), child: Text(tr('website'))),
      ]),
    );
  }

  Widget sidebar() {
    return Container(
      width: 260,
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(border: Border(right: BorderSide(color: cBorder))),
      child: Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: cPanel, borderRadius: BorderRadius.circular(rLg), border: Border.fromBorderSide(line)),
          child: const Brand(),
        ),
        const SizedBox(height: 12),
        NavItem(icon: 'activity', label: tr('navActivity'), active: tab == 0, onTap: () => setState(() => tab = 0)),
        const SizedBox(height: 8),
        NavItem(icon: 'settings', label: tr('navSettings'), active: tab == 1, onTap: () => setState(() => tab = 1)),
      ]),
    );
  }

  Widget bottomNav() {
    Widget item(String icon, String label, int index) => Expanded(
          child: HoverBox(
            onTap: () => setState(() => tab = index),
            builder: (hovered) => Container(
              height: 56,
              color: hovered ? cSoft : Colors.transparent,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Opacity(opacity: tab == index ? 1 : 0.6, child: SvgPicture.asset('assets/icons/$icon.svg', width: 20, height: 20)),
                const SizedBox(height: 4),
                Text(label, style: TextStyle(fontSize: 12, fontWeight: tab == index ? FontWeight.w800 : FontWeight.w500)),
              ]),
            ),
          ),
        );
    return Container(
      decoration: const BoxDecoration(color: cPanel, border: Border(top: BorderSide(color: cBorder))),
      child: Row(children: [item('activity', tr('navActivity'), 0), item('settings', tr('navSettings'), 1)]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final narrow = c.maxWidth < narrowWidth;
      final title = tab == 0 ? tr('navActivity') : tr('navSettings');
      final pad = narrow ? 12.0 : 18.0;
      return Scaffold(
        body: Column(children: [
          topbar(narrow),
          Expanded(
            child: Row(children: [
              if (!narrow) sidebar(),
              Expanded(
                child: Column(children: [
                  if (serviceDown) banner() else if (isPaused) pausedBanner(),
                  Expanded(
                    child: ListView(padding: EdgeInsets.fromLTRB(pad, pad, pad, 28), children: [
                      Wrap(spacing: 16, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
                        if (tab == 0) statusChip(),
                      ]),
                      const SizedBox(height: 14),
                      tab == 0 ? activity(narrow) : SettingsPage(onWithdraw: widget.onWithdraw),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
          if (narrow) bottomNav(),
        ]),
      );
    });
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.onWithdraw});

  final VoidCallback onWithdraw;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? auto;

  @override
  void initState() {
    super.initState();
    autostartEnabled().then((v) {
      if (mounted) setState(() => auto = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(tr('autostart'), style: const TextStyle(fontWeight: FontWeight.w700))),
          Switch(
            value: auto ?? false,
            onChanged: auto == null
                ? null
                : (v) async {
                    await setAutostart(v);
                    final now = await autostartEnabled();
                    if (mounted) setState(() => auto = now);
                  },
          ),
        ]),
        const Divider(height: 28),
        Row(children: [
          Expanded(child: Text(tr('language'), style: const TextStyle(fontWeight: FontWeight.w700))),
          LanguagePicker(onChanged: () => setState(() {})),
        ]),
        const Divider(height: 28),
        Text(tr('dataFolder'), style: const TextStyle(color: cMuted, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(child: SelectableText(dataDir())),
          IconButton(
            tooltip: tr('copy'),
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: dataDir()));
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(SnackBar(content: Text(tr('copied')), duration: const Duration(seconds: 2)));
            },
          ),
        ]),
        const Divider(height: 28),
        Wrap(spacing: 8, children: [
          TextButton(onPressed: () => open(privacyUrl), child: Text(tr('privacy'))),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: cDanger),
            onPressed: widget.onWithdraw,
            child: Text(tr('withdraw')),
          ),
        ]),
      ]),
    );
  }
}
