import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';
import 'chart.dart';
import 'data.dart';
import 'icons.dart';
import 'l10n.dart';
import 'mark.dart';
import 'picker.dart';
import 'window_state.dart';
import 'theme.dart';
import 'updater.dart';
import 'win.dart';

const appName = 'Wolium';
const siteUrl = 'https://wolium.netlify.app/';
const privacyUrl = 'https://wolium.netlify.app/privacy-policy/';
const narrowWidth = 760.0;
const staleSeconds = 7;

Locale materialLocale(String code) {
  final base = code.split('-').first;
  return Locale(kMaterialSupportedLanguages.contains(base) ? base : 'en');
}

void main() {
  if (!claimSingleInstance()) exit(0);
  migrateLegacyData();
  loadLanguage();
  WidgetsFlutterBinding.ensureInitialized();
  WindowState.instance.restore();
  runApp(const WoliumApp());
  WindowState.instance.attach();
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
        locale: materialLocale(language.value),
        supportedLocales: [for (final c in languages.keys) materialLocale(c)],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
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
  late DateTime from;
  late DateTime to;
  String preset = 'day';
  String? hoverApp;
  List<AppUsage> rows = [];
  Duration? beat;
  bool hasDb = false;
  DateTime? startedAt = DateTime.now();
  int ticks = 0;
  bool isPaused = false;
  bool liveMode = false;
  List<Contrib> contribs = [];
  String? rangeKey;
  double viewFrom = 0;
  double viewTo = 86400;
  int viewBucket = 300;
  int loadW0 = -1;
  int loadW1 = -1;
  int loadBin = 0;
  bool loadSess = false;
  String? sortKey;
  bool sortAsc = false;

  int get dayCount => DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays + 1;

  void loadChart({bool force = false}) {
    final total = dayCount * 86400;
    final sp = viewTo - viewFrom;
    final useSess = sp <= 7 * 86400;
    final bin = viewBucket >= 3600 ? 12 : (viewBucket >= 900 ? 3 : 1);
    final inside = loadW0 >= 0 && viewFrom >= loadW0 && viewTo <= loadW1;
    if (!force && inside && bin == loadBin && useSess == loadSess) return;
    final w0 = math.max(0, viewFrom - sp).floor();
    final w1 = math.min(total.toDouble(), viewTo + sp).ceil();
    contribs = usage.contribs(from, w0, w1, bin, useSess);
    loadW0 = w0;
    loadW1 = w1;
    loadBin = bin;
    loadSess = useSess;
  }

  void onChartView(double a, double b, int bucketSec) {
    if (!mounted) return;
    viewFrom = a;
    viewTo = b;
    viewBucket = bucketSec;
    setState(() => loadChart());
  }

  void sortBy(String k) {
    setState(() {
      if (sortKey == k) {
        sortAsc = !sortAsc;
      } else {
        sortKey = k;
        sortAsc = k == 'app';
      }
    });
  }

  Widget sortHead(String label, String k, TextStyle head) {
    final on = sortKey == k;
    return HoverBox(
      onTap: () => sortBy(k),
      builder: (hovered) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: EllipsisText(label, style: head.copyWith(color: on || hovered ? cPrimary : cMuted))),
          if (on) Text(sortAsc ? ' \u25B2' : ' \u25BC', style: const TextStyle(color: cPrimary, fontSize: 10)),
        ]),
      ),
    );
  }
  String? only;
  Map<String, AppMeta> names = {};
  Metric metric = Metric.focused;
  UpdateInfo? update;
  bool updating = false;
  double updateProgress = 0;
  bool updateFailed = false;
  final settings = Settings.load();

  @override
  void initState() {
    super.initState();
    autostartEnabled();
    to = dateOnly(DateTime.now());
    from = to;
    requestFlush();
    checkForUpdate();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (++ticks % 20 == 0) requestFlush();
      if (ticks % 21600 == 0) checkForUpdate();
      refresh();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    usage.close();
    super.dispose();
  }

  Future<void> checkForUpdate() async {
    if (!settings.autoUpdate || updating) return;
    final info = await checkUpdate();
    if (mounted && info != null) setState(() => update = info);
  }

  Future<void> runUpdate() async {
    final info = update;
    if (info == null || updating) return;
    setState(() {
      updating = true;
      updateFailed = false;
      updateProgress = 0;
    });
    final ok = await downloadAndInstall(info, (v) {
      if (mounted) setState(() => updateProgress = v);
    });
    if (ok) exit(0);
    if (mounted) {
      setState(() {
        updating = false;
        updateFailed = true;
      });
    }
  }

  Widget updateBanner() {
    final info = update!;
    return Container(
      width: double.infinity,
      color: cPrimary.withValues(alpha: 0.14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('${tr('updateAvailable')}: ${info.current} \u2192 ${info.latest}', style: const TextStyle(color: cPrimary, fontWeight: FontWeight.w700)),
        if (updating)
          SizedBox(width: 160, child: LinearProgressIndicator(value: updateProgress > 0 ? updateProgress : null, color: cPrimary, backgroundColor: cBorder))
        else
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 34)),
            onPressed: runUpdate,
            child: Text(tr('updateAction')),
          ),
        if (updating) Text(tr('updating'), style: const TextStyle(color: cMuted)),
        if (updateFailed) Text(tr('updateFailed'), style: const TextStyle(color: cDanger)),
      ]),
    );
  }

  DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  String keyOf(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

  String shown(DateTime d) => '${two(d.day)}.${two(d.month)}.${d.year}';

  void applyPreset(String p) {
    final today = dateOnly(DateTime.now());
    final span = {'day': 0, 'week': 6, 'month': 29, 'year': 364}[p] ?? 0;
    preset = p;
    to = today;
    from = today.subtract(Duration(days: span));
  }

  void refresh() {
    if (preset != 'custom') applyPreset(preset);
    final today = dateOnly(DateTime.now());
    final fk = keyOf(from);
    final tk = keyOf(to);
    final b = usage.sinceHeartbeat();
    final up = b != null && b <= const Duration(seconds: staleSeconds);
    final l = up && from == to && to == today ? usage.live() : null;
    final rk = '$fk|$tk';
    setState(() {
      hasDb = usage.available;
      days = usage.days();
      beat = b;
      isPaused = usage.paused;
      liveMode = l != null;
      rows = l ?? usage.range(fk, tk);
      final every = dayCount > 1 ? 30 : 5;
      final changed = rangeKey != rk;
      if (changed) {
        viewFrom = 0;
        viewTo = dayCount * 86400.0;
        viewBucket = bucketSecFor(viewTo, 600);
      }
      if (changed || ticks % every == 0) {
        loadChart(force: true);
        names = usage.names();
        rangeKey = rk;
      }
    });
  }

  Future<void> pickRange() async {
    final today = dateOnly(DateTime.now());
    var first = DateTime(2020);
    if (days.isNotEmpty) {
      final parsed = DateTime.tryParse(days.last);
      if (parsed != null) first = dateOnly(parsed);
    }
    final picked = await showDateRangePicker(
      context: context,
      firstDate: first.isAfter(from) ? from : first,
      lastDate: today,
      initialDateRange: DateTimeRange(start: from, end: to.isAfter(today) ? today : to),
    );
    if (picked == null) return;
    setState(() {
      preset = 'custom';
      from = dateOnly(picked.start);
      to = dateOnly(picked.end);
    });
    requestFlush();
    refresh();
  }

  Widget rangeSelect() {
    return SelectBox<String>(
      value: preset,
      items: [
        DropdownMenuItem(value: 'day', child: Text(tr('presetDay'))),
        DropdownMenuItem(value: 'week', child: Text(tr('presetWeek'))),
        DropdownMenuItem(value: 'month', child: Text(tr('presetMonth'))),
        DropdownMenuItem(value: 'year', child: Text(tr('presetYear'))),
        DropdownMenuItem(value: 'custom', child: Text(preset == 'custom' ? '${shown(from)} - ${shown(to)}' : tr('presetCustom'))),
      ],
      onChanged: (v) {
        if (v == null) return;
        if (v == 'custom') {
          pickRange();
          return;
        }
        setState(() => applyPreset(v));
        requestFlush();
        refresh();
      },
    );
  }

  Future<String?> exportCsv() async {
    final today = dateOnly(DateTime.now());
    var first = DateTime(2020);
    if (days.isNotEmpty) {
      final parsed = DateTime.tryParse(days.last);
      if (parsed != null) first = dateOnly(parsed);
    }
    final picked = await showDateRangePicker(
      context: context,
      firstDate: first.isAfter(from) ? from : first,
      lastDate: today,
      helpText: tr('exportRange'),
      initialDateRange: DateTimeRange(start: from, end: to.isAfter(today) ? today : to),
    );
    if (picked == null) return null;
    final fk = keyOf(dateOnly(picked.start));
    final tk = keyOf(dateOnly(picked.end));
    requestFlush();
    final home = Platform.environment['USERPROFILE'];
    final docs = home == null ? null : '$home${Platform.pathSeparator}Documents';
    final path = saveFileDialog(
      title: tr('exportSaveTitle'),
      filter: 'CSV (*.csv)\u0000*.csv\u0000',
      name: 'wolium_${fk}_$tk.csv',
      ext: 'csv',
      dir: docs != null && Directory(docs).existsSync() ? docs : dataDir(),
    );
    if (path == null) return null;
    String q(String v) => '"${v.replaceAll('"', '""')}"';
    final b = StringBuffer('\uFEFF');
    b.writeln('${tr('app')},${tr('focused')} (s),${tr('open')} (s),${tr('minimized')} (s),${tr('background')} (s),${tr('total')} (s)');
    for (final r in usage.range(fk, tk)) {
      b.writeln('${q(r.title)},${r.ms[0] ~/ 1000},${r.ms[1] ~/ 1000},${r.ms[2] ~/ 1000},${r.ms[3] ~/ 1000},${r.total ~/ 1000}');
    }
    File(path).writeAsStringSync(b.toString());
    return path;
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
        Flexible(child: EllipsisText(r.now == null ? '-' : stateText(r.now), style: TextStyle(color: c, fontWeight: FontWeight.w700))),
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
    int val(AppUsage r) {
      switch (sortKey) {
        case 'focused':
          return r.ms[0];
        case 'open':
          return r.ms[1];
        case 'minimized':
          return r.ms[2];
        case 'background':
          return r.ms[3];
        case 'total':
          return r.total;
        case 'now':
          return r.now == null ? 0 : 4 - r.now!;
        default:
          return metricValue(r);
      }
    }

    list.sort((a, b) {
      if (sortKey == 'app') {
        final c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
        return sortAsc ? c : -c;
      }
      final c = sortKey == null ? val(b).compareTo(val(a)) : (sortAsc ? val(a).compareTo(val(b)) : val(b).compareTo(val(a)));
      return c != 0 ? c : b.total.compareTo(a.total);
    });
    if (only != null) {
      final i = list.indexWhere((r) => r.app == only);
      if (i > 0) list.insert(0, list.removeAt(i));
    }
    return list;
  }

  void toggleOnly(String app) {
    setState(() => only = only == app ? null : app);
  }

  List<String> appChoices() {
    final set = <String>{for (final r in rows) r.app, for (final c in contribs) c.app};
    if (only != null) set.add(only!);
    final list = set.toList()..sort((a, b) => titleOf(a).toLowerCase().compareTo(titleOf(b).toLowerCase()));
    return list;
  }

  void showChartHelp() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: cPanel,
        title: Text(tr('helpTitle')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('helpWhat')),
            const SizedBox(height: 12),
            Text(tr('helpMouse'), style: const TextStyle(color: cMuted)),
            const SizedBox(height: 8),
            Text(tr('helpTouch'), style: const TextStyle(color: cMuted)),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('ok')))],
      ),
    );
  }

  Widget chartPanel(bool narrow) {
    return Panel(
      padding: EdgeInsets.all(narrow ? 12 : 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(tr('chartTitle'), style: const TextStyle(fontWeight: FontWeight.w800)),
          rangeSelect(),
          SelectBox<Metric>(
            value: metric,
            items: [for (final m in Metric.values) DropdownMenuItem(value: m, child: Text(metricLabel(m)))],
            onChanged: (v) => setState(() => metric = v ?? metric),
          ),
          AppPicker(
            value: only,
            items: [for (final app in appChoices()) PickerItem(app, titleOf(app), iconOf(app, 20))],
            current: only == null ? null : PickerItem(only!, titleOf(only!), iconOf(only!, 20)),
            onChanged: (v) => setState(() => only = v),
          ),
          IconButton(
            tooltip: tr('helpTitle'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.help_outline, size: 20, color: cMuted),
            onPressed: showChartHelp,
          ),
        ]),
        const SizedBox(height: 10),
        ActivityChart(first: from, total: dayCount * 86400, contribs: contribs, only: only, metric: metric, title: titleOf, icon: iconOf, height: narrow ? 190 : 240, onView: onChartView),
      ]),
    );
  }

  Widget wideTable(TextStyle head) {
    Widget hov(String? app, Widget child) => MouseRegion(
          onEnter: app == null ? null : (_) => setState(() => hoverApp = app),
          onExit: app == null ? null : (_) => setState(() => hoverApp = hoverApp == app ? null : hoverApp),
          child: child,
        );
    Widget cell(String t, {TextStyle? style, String? app}) => hov(
          app,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
            child: EllipsisText(t, style: style),
          ),
        );
    return Table(
      columnWidths: const {0: FlexColumnWidth(3)},
      children: [
        TableRow(children: [
          sortHead(tr('app'), 'app', head),
          if (liveMode) sortHead(tr('now'), 'now', head),
          sortHead(tr('focused'), 'focused', head),
          sortHead(tr('open'), 'open', head),
          sortHead(tr('minimized'), 'minimized', head),
          sortHead(tr('background'), 'background', head),
          sortHead(tr('total'), 'total', head),
        ]),
        for (final r in sortedRows())
          TableRow(
            decoration: only == r.app
                ? BoxDecoration(color: cSoft.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(8), border: Border.all(color: cPrimary))
                : BoxDecoration(color: hoverApp == r.app ? cSoft.withValues(alpha: 0.35) : null, border: const Border(top: BorderSide(color: cBorder))),
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => toggleOnly(r.app),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onEnter: (_) => setState(() => hoverApp = r.app),
                  onExit: (_) => setState(() => hoverApp = hoverApp == r.app ? null : hoverApp),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                    child: Row(children: [
                      AppIcon(title: r.title, path: r.path, size: 22),
                      const SizedBox(width: 8),
                      Expanded(child: EllipsisText(r.title, style: TextStyle(fontWeight: FontWeight.w700, color: only == r.app ? cPrimary : null))),
                    ]),
                  ),
                ),
              ),
              if (liveMode) hov(r.app, nowCell(r)),
              for (final i in [0, 1, 2, 3]) cell(r.ms[i] == 0 ? '-' : formatMs(r.ms[i]), app: r.app),
              cell(formatMs(r.total), style: const TextStyle(fontWeight: FontWeight.w800), app: r.app),
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
      Wrap(children: [
        sortHead(tr('app'), 'app', head),
        sortHead(tr('total'), 'total', head),
        sortHead(tr('focused'), 'focused', head),
        sortHead(tr('open'), 'open', head),
      ]),
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
              Expanded(child: EllipsisText(r.title, style: const TextStyle(fontWeight: FontWeight.w800))),
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
                  if (update != null) updateBanner(),
                  if (serviceDown) banner() else if (isPaused) pausedBanner(),
                  Expanded(
                    child: ListView(padding: EdgeInsets.fromLTRB(pad, pad, pad, 28), children: [
                      Wrap(spacing: 16, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
                        if (tab == 0) statusChip(),
                      ]),
                      const SizedBox(height: 14),
                      tab == 0 ? activity(narrow) : SettingsPage(
                        onWithdraw: widget.onWithdraw,
                        onExport: exportCsv,
                        onCheck: () async {
                          final info = await checkUpdate();
                          if (mounted) setState(() => update = info);
                          return info;
                        },
                      ),
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
  const SettingsPage({super.key, required this.onWithdraw, required this.onCheck, required this.onExport});

  final VoidCallback onWithdraw;
  final Future<UpdateInfo?> Function() onCheck;
  final Future<String?> Function() onExport;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? auto = autostartCache;
  final prefs = Settings.load();
  late bool autoUpdate = prefs.autoUpdate;
  String? checkText;
  String? exportedPath;
  String? exportError;
  bool checking = false;
  late bool localApi = prefs.flag('localapi');

  Future<void> toggleApi(bool v) async {
    if (v) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('localApi')),
          content: Text(tr('localApiWarn')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('cancel'))),
            TextButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('enable'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    prefs.setFlag('localapi', v);
    setState(() => localApi = v);
  }

  @override
  void initState() {
    super.initState();
    autostartEnabled().then((v) {
      if (mounted && v != auto) setState(() => auto = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(tr('version'), style: const TextStyle(fontWeight: FontWeight.w700))),
          Text(installedVersion().isEmpty ? '-' : installedVersion(), style: const TextStyle(color: cMuted, fontWeight: FontWeight.w700)),
        ]),
        const Divider(height: 28),
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
          Expanded(child: Text(tr('autoUpdate'), style: const TextStyle(fontWeight: FontWeight.w700))),
          Switch(
            value: autoUpdate,
            onChanged: (v) {
              prefs.autoUpdate = v;
              setState(() => autoUpdate = v);
            },
          ),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          OutlinedButton(
            onPressed: checking
                ? null
                : () async {
                    setState(() {
                      checking = true;
                      checkText = tr('checking');
                    });
                    final info = await widget.onCheck();
                    if (!mounted) return;
                    setState(() {
                      checking = false;
                      checkText = info == null ? tr('upToDate') : '${tr('updateAvailable')}: ${info.current} \u2192 ${info.latest}';
                    });
                  },
            child: Text(tr('checkNow')),
          ),
          if (checkText != null) Text(checkText!, style: const TextStyle(color: cMuted)),
        ]),
        const Divider(height: 28),
        Row(children: [
          Expanded(child: Text(tr('localApi'), style: const TextStyle(fontWeight: FontWeight.w700))),
          Switch(value: localApi, onChanged: toggleApi),
        ]),
        Text(tr('localApiHint'), style: const TextStyle(color: cMuted, fontSize: 12)),
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
            tooltip: tr('openFolder'),
            icon: const Icon(Icons.folder_open, size: 18),
            onPressed: () => Process.run('explorer', [dataDir()]),
          ),
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
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          OutlinedButton(
            onPressed: () async {
              String? path;
              String? err;
              try {
                path = await widget.onExport();
              } catch (_) {
                err = tr('exportFailed');
              }
              if (!mounted) return;
              if (path != null || err != null) {
                setState(() {
                  exportedPath = path;
                  exportError = err;
                });
              }
            },
            child: Text(tr('exportCsv')),
          ),
        ]),
        if (exportError != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(exportError!, style: const TextStyle(color: cDanger, fontWeight: FontWeight.w700))),
        if (exportedPath != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: cOk.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(rSm), border: Border.all(color: cOk)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(tr('exported'), style: const TextStyle(color: cOk, fontWeight: FontWeight.w800))),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18, color: cMuted),
                  onPressed: () => setState(() => exportedPath = null),
                ),
              ]),
              SelectableText(exportedPath!, style: const TextStyle(color: cMuted, fontSize: 12)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton(onPressed: () => Process.run('explorer', ['/select,', exportedPath!]), child: Text(tr('openFolder'))),
                OutlinedButton(onPressed: () => Process.run('explorer', [exportedPath!]), child: Text(tr('openFile'))),
              ]),
            ]),
          ),
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
