import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';
import 'data.dart';
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

  void refresh() {
    final d = usage.days();
    final selected = day != null && d.contains(day) ? day : (d.isEmpty ? null : d.first);
    setState(() {
      hasDb = usage.available;
      days = d;
      day = selected;
      rows = selected == null ? [] : usage.day(selected);
      beat = usage.sinceHeartbeat();
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
          cell(tr('focused'), style: head),
          cell(tr('open'), style: head),
          cell(tr('minimized'), style: head),
          cell(tr('background'), style: head),
          cell(tr('total'), style: head),
        ]),
        for (final r in rows)
          TableRow(
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: cBorder))),
            children: [
              cell(r.title, style: const TextStyle(fontWeight: FontWeight.w700), ellipsis: true),
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
      for (final r in rows)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(rMd),
            border: Border.fromBorderSide(line),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
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
    ]);
  }

  Widget activity(bool narrow) {
    if (!hasDb || rows.isEmpty) return Panel(child: Text(tr('noData')));
    const head = TextStyle(color: cMuted, fontWeight: FontWeight.w800);
    return Panel(
      padding: EdgeInsets.all(narrow ? 12 : 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        dateRow(head),
        const SizedBox(height: 8),
        narrow ? compactList(head) : wideTable(head),
      ]),
    );
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
                  if (serviceDown) banner(),
                  Expanded(
                    child: ListView(padding: EdgeInsets.fromLTRB(pad, pad, pad, 28), children: [
                      Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
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
