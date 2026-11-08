import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'data.dart';
import 'l10n.dart';
import 'theme.dart';

const appName = 'Wolium';
const siteUrl = 'https://wolium.netlify.app/';
const privacyUrl = 'https://wolium.netlify.app/privacy-policy/';

void main() {
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
  Widget build(BuildContext context) {
    if (accepted) return const Shell();
    return Scaffold(
      body: Center(
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
                Row(children: [
                  FilledButton(
                    onPressed: () {
                      settings.accepted = true;
                      setState(() => accepted = true);
                    },
                    child: Text(tr('accept')),
                  ),
                  const Spacer(),
                  LanguagePicker(onChanged: () => setState(() {})),
                ]),
              ],
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
    return Row(children: [
      Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(rSm),
          border: Border.fromBorderSide(line),
          color: cSoft,
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.asset('assets/icon/wolium_256.png', fit: BoxFit.cover),
      ),
      const SizedBox(width: 10),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
  const Shell({super.key});

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
  Duration? stale;
  bool hasDb = false;

  @override
  void initState() {
    super.initState();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 2), (_) => refresh());
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
      stale = usage.sinceLastWrite();
    });
  }

  bool get serviceDown => stale != null && stale! > const Duration(seconds: 30);

  Widget activity() {
    if (!hasDb) return Panel(child: Text(tr('serviceMissing')));
    if (rows.isEmpty) return Panel(child: Text(tr('noData')));
    const head = TextStyle(color: cMuted, fontWeight: FontWeight.w800);
    Widget cell(String t, {TextStyle? style, bool ellipsis = false}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
          child: Text(t, style: style, overflow: ellipsis ? TextOverflow.ellipsis : null),
        );
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(tr('date'), style: head),
          const SizedBox(width: 12),
          SelectBox<String>(
            value: day,
            items: [for (final d in days) DropdownMenuItem(value: d, child: Text(d))],
            onChanged: (v) {
              day = v;
              refresh();
            },
          ),
        ]),
        const SizedBox(height: 12),
        Table(
          columnWidths: const {0: FlexColumnWidth(3)},
          children: [
            TableRow(children: [
              cell(tr('app'), style: head),
              cell(tr('focused'), style: head),
              cell(tr('open'), style: head),
              cell(tr('minimized'), style: head),
              cell(tr('background'), style: head),
            ]),
            for (final r in rows)
              TableRow(
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: cBorder))),
                children: [
                  cell(r.app, style: const TextStyle(fontWeight: FontWeight.w700), ellipsis: true),
                  for (final i in [0, 1, 2, 3]) cell(r.ms[i] == 0 ? '-' : formatMs(r.ms[i])),
                ],
              ),
          ],
        ),
      ]),
    );
  }

  Widget topbar() {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(color: cPanel, border: Border(bottom: BorderSide(color: cBorder))),
      child: Row(children: [
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
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: cPanel,
            borderRadius: BorderRadius.circular(rLg),
            border: Border.fromBorderSide(line),
          ),
          child: const Brand(),
        ),
        const SizedBox(height: 12),
        NavItem(icon: Icons.bar_chart, label: tr('navActivity'), active: tab == 0, onTap: () => setState(() => tab = 0)),
        const SizedBox(height: 8),
        NavItem(icon: Icons.settings, label: tr('navSettings'), active: tab == 1, onTap: () => setState(() => tab = 1)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = tab == 0 ? tr('navActivity') : tr('navSettings');
    return Scaffold(
      body: Column(children: [
        topbar(),
        Expanded(
          child: Row(children: [
            sidebar(),
            Expanded(
              child: Column(children: [
                if (serviceDown)
                  Container(
                    width: double.infinity,
                    color: cDanger.withValues(alpha: 0.18),
                    padding: const EdgeInsets.all(10),
                    child: Text(tr('serviceStale'), style: const TextStyle(color: cDanger, fontWeight: FontWeight.w700)),
                  ),
                Expanded(
                  child: ListView(padding: const EdgeInsets.fromLTRB(18, 18, 18, 28), children: [
                    Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 14),
                    tab == 0 ? activity() : const SettingsPage(),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

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
        Text(dataDir()),
        const Divider(height: 28),
        TextButton(onPressed: () => open(privacyUrl), child: Text(tr('privacy'))),
      ]),
    );
  }
}
