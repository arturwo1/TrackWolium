import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';
import 'appctl.dart';
import 'chart.dart';
import 'data.dart';
import 'device.dart';
import 'forecast.dart';
import 'icons.dart';
import 'l10n.dart';
import 'mark.dart';
import 'picker.dart';
import 'reschart.dart';
import 'window_state.dart';
import 'theme.dart';
import 'updater.dart';
import 'android_collector.dart';
import 'package:path_provider/path_provider.dart';
import 'posix.dart';
import 'haptics.dart';
import 'discord_posix.dart';
import 'win.dart';

const appName = 'Wolium';
const siteUrl = 'https://wolium.netlify.app/';
const privacyUrl = 'https://wolium.netlify.app/privacy-policy/';
const narrowWidth = 760.0;
const staleSeconds = 7;
final bool multiState = !Platform.isAndroid;

Locale materialLocale(String code) {
  final base = code.split('-').first;
  return Locale(kMaterialSupportedLanguages.contains(base) ? base : 'en');
}

AndroidCollector? collector;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows && !Platform.isAndroid) posixTouchAlive();
  if (Platform.isAndroid) androidBase = (await getApplicationSupportDirectory()).path;
  if (!claimSingleInstance()) exit(0);
  migrateLegacyData();
  loadLanguage();
  await loadDefaultDeviceName();
  deviceId();
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows && !Platform.isAndroid) posixTouchAlive();
  WindowState.instance.restore();
  if (Platform.isAndroid) collector = AndroidCollector(UsageBridge())..start();
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
    if (accepted) {
      startService();
      collector?.bridge.requestNotifications();
      if (Platform.isAndroid && settings.flag('localapi')) collector?.bridge.setApiService(true);
    }
  }

  void accept() {
    settings.accepted = true;
    startService();
    collector?.sync();
    collector?.bridge.requestNotifications();
    setState(() => accepted = true);
  }

  void withdraw() {
    settings.accepted = false;
    if (Platform.isAndroid) collector?.bridge.setApiService(false);
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
    return ValueListenableBuilder<String>(valueListenable: language, builder: (context, _, __) => brandRow());
  }

  Widget brandRow() {
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
  String? menuApp;
  List<AppUsage> rows = [];
  Duration? beat;
  bool hasDb = false;
  DateTime? startedAt = DateTime.now();
  int ticks = 0;
  bool isPaused = false;
  bool liveMode = false;
  List<Contrib> contribs = [];
  List<PresenceRow> presenceRows = [];
  final rpcNames = <String, String>{};
  final rpcAssets = <String, Map<String, String>>{};
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
  Map<String, ResAgg> resMap = {};
  List<ResPoint> resPts = [];
  List<SysPoint> sysPts = [];
  final resSel = <String>{};

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
    contribs = usage.contribs(from, w0, w1, bin, useSess).where((c) => !Hidden.has(c.app)).toList();
    presenceRows = usage.presence(from, w0, w1);
    final en = MetricPrefs.enabled.value;
    resPts = en.any(procMetricIds.contains) ? usage.resPoints(from, w0, w1, bin) : [];
    sysPts = en.any(sysMetricIds.contains) ? usage.sysPoints(from, w0, w1) : [];
    for (final r in presenceRows) {
      if (r.name.isEmpty && r.clientId.isNotEmpty) resolveRpcName(r.clientId);
    }
    loadW0 = w0;
    loadW1 = w1;
    loadBin = bin;
    loadSess = useSess;
  }

  Future<dynamic> fetchJson(String url) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      return jsonDecode(await res.transform(utf8.decoder).join());
    } finally {
      client.close();
    }
  }

  Future<void> resolveRpcName(String id) async {
    if (rpcNames.containsKey(id)) return;
    rpcNames[id] = '';
    rpcAssets[id] = {};
    try {
      final info = await fetchJson('https://discord.com/api/v10/applications/$id/rpc');
      final name = info is Map ? info['name'] : null;
      if (name is String && mounted) setState(() => rpcNames[id] = name);
    } catch (_) {}
    try {
      final list = await fetchJson('https://discord.com/api/v10/oauth2/applications/$id/assets');
      if (list is List && mounted) {
        setState(() {
          for (final a in list) {
            if (a is Map && a['name'] is String && a['id'] is String) rpcAssets[id]![a['name'] as String] = a['id'] as String;
          }
        });
      }
    } catch (_) {}
  }

  String? rpcAssetUrl(String client, String key) {
    if (key.startsWith('mp:')) return 'https://media.discordapp.net/${key.substring(3)}';
    if (key.startsWith('http://') || key.startsWith('https://')) return key;
    if (RegExp(r'^\d{10,}$').hasMatch(key)) return 'https://cdn.discordapp.com/app-assets/$client/$key.png';
    final id = rpcAssets[client]?[key];
    return id == null ? null : 'https://cdn.discordapp.com/app-assets/$client/$id.png';
  }

  PresenceMark presenceMark(PresenceRow r) {
    Map<String, dynamic> data = {};
    if (r.raw.isNotEmpty) {
      try {
        final v = jsonDecode(r.raw);
        if (v is Map) data = Map<String, dynamic>.from(v);
      } catch (_) {}
    }
    return PresenceMark(r.sec, presenceText(r), r.clientId, r.name.isNotEmpty ? r.name : (rpcNames[r.clientId] ?? ''), data);
  }

  String presenceText(PresenceRow r) {
    final who = r.name.isNotEmpty ? r.name : (rpcNames[r.clientId] ?? '');
    final what = [r.details, r.state].where((e) => e.isNotEmpty).join(' - ');
    if (what.isEmpty) return '';
    return who.isEmpty ? what : '$who: $what';
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
    final box = HoverBox(
      onTap: () => sortBy(k),
      builder: (hovered) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: EllipsisText(label, style: head.copyWith(color: on || hovered ? cPrimary : cMuted))),
          if (on) Text(sortAsc ? ' \u25B2' : ' \u25BC', style: const TextStyle(color: cPrimary, fontSize: 10)),
        ]),
      ),
    );
    if (Platform.isAndroid) return box;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: (d) => columnMenu(d.globalPosition),
      child: box,
    );
  }

  List<String> columnChoices() => [
        if (liveMode) 'now',
        if (multiState) ...['focused', 'open', 'minimized', 'background'],
        'total',
        if (multiState) ...procMetricIds.where(MetricPrefs.enabled.value.contains),
      ];

  List<String> activeColumns() => [for (final c in columnChoices()) if (ColumnPrefs.shown(c)) c];

  String columnLabel(String id) => procMetricIds.contains(id) ? metricName(id) : tr(id);

  RelativeRect menuPosition(Offset at) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    return RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size);
  }

  Future<T?> darkMenu<T>(Offset at, List<PopupMenuEntry<T>> items) => showMenu<T>(
        context: context,
        position: menuPosition(at),
        color: cBg,
        surfaceTintColor: Colors.transparent,
        shadowColor: const Color(0x99000000),
        elevation: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rSm), side: const BorderSide(color: cBorder)),
        items: items,
      );

  Future<void> columnMenu(Offset at) async {
    final ids = columnChoices();
    final chosen = await darkMenu<String>(at, [
      PopupMenuItem<String>(enabled: false, height: 32, child: Text(tr('colMenu'), style: const TextStyle(color: cMuted, fontWeight: FontWeight.w800))),
      for (final id in ids)
        CheckedPopupMenuItem<String>(
          value: id,
          checked: ColumnPrefs.shown(id),
          child: Text(columnLabel(id), style: const TextStyle(color: cPrimary)),
        ),
    ]);
    if (chosen == null) return;
    ColumnPrefs.set(chosen, !ColumnPrefs.shown(chosen));
  }

  void toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  Future<bool> confirmEnd(AppUsage r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: cPanel,
        title: Text(tr('actEnd')),
        content: Text(tr('actEndConfirm').replaceAll('{app}', r.title)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('cancel'))),
          TextButton(style: TextButton.styleFrom(foregroundColor: cDanger), onPressed: () => Navigator.pop(c, true), child: Text(tr('actEnd'))),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> rowMenu(AppUsage r, Offset at) async {
    Widget item(IconData icon, String text, {Color? color, bool on = true}) {
      final c = on ? (color ?? cPrimary) : cMuted.withValues(alpha: 0.45);
      return Row(children: [Icon(icon, size: 18, color: on ? (color ?? cMuted) : c), const SizedBox(width: 10), Text(text, style: TextStyle(color: c))]);
    }
    final control = appControlSupported;
    final live = control ? await appLive(r.app) : const AppLive(false, false);
    final exists = r.path.isNotEmpty && File(r.path).existsSync();
    setState(() => menuApp = r.app);
    final v = await darkMenu<String>(at, [
      if (control) PopupMenuItem<String>(value: 'focus', enabled: live.window, child: item(Icons.open_in_new, tr('actFocus'), on: live.window)),
      if (control && r.path.isNotEmpty) PopupMenuItem<String>(value: 'locate', enabled: exists, child: item(Icons.folder_open, tr('actLocate'), on: exists)),
      if (control) PopupMenuItem<String>(value: 'end', enabled: live.running, child: item(Icons.power_settings_new, tr('actEnd'), color: cDanger, on: live.running)),
      if (control) const PopupMenuDivider(),
      PopupMenuItem<String>(value: 'hide', child: item(Icons.visibility_off_outlined, tr('actHide'))),
    ]);
    if (mounted) setState(() => menuApp = null);
    switch (v) {
      case 'focus':
        if (!await focusApp(r.app)) toast(tr('actNoWindow'));
        break;
      case 'locate':
        await openPath(r.path, select: true);
        break;
      case 'end':
        if (!await confirmEnd(r)) return;
        final n = await endApp(r.app);
        toast(n > 0 ? tr('actEnded') : tr('actEndFailed'));
        break;
      case 'hide':
        Hidden.hide(r.app, r.title);
        break;
    }
  }

  Future<void> androidMenu(AppUsage r) async {
    buzz(1);
    final bridge = collector?.bridge;
    if (bridge == null) return;
    final v = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: cPanel,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: AppIcon(title: r.title, path: r.path, size: 28), title: Text(r.title, style: const TextStyle(fontWeight: FontWeight.w800)), subtitle: Text(r.app, style: const TextStyle(color: cMuted, fontSize: 12))),
          const Divider(height: 1),
          ListTile(leading: const Icon(Icons.open_in_new), title: Text(tr('actOpenApp')), onTap: () => Navigator.pop(c, 'open')),
          ListTile(leading: const Icon(Icons.info_outline), title: Text(tr('actAppInfo')), onTap: () => Navigator.pop(c, 'info')),
        ]),
      ),
    );
    switch (v) {
      case 'open':
        if (!await bridge.openApp(r.app)) toast(tr('actEndFailed'));
        break;
      case 'info':
        await bridge.appInfo(r.app);
        break;
    }
  }

  String cellText(String id, AppUsage r) {
    final a = resMap[r.app];
    switch (id) {
      case 'focused':
        return r.ms[0] == 0 ? '-' : formatMs(r.ms[0]);
      case 'open':
        return r.ms[1] == 0 ? '-' : formatMs(r.ms[1]);
      case 'minimized':
        return r.ms[2] == 0 ? '-' : formatMs(r.ms[2]);
      case 'background':
        return r.ms[3] == 0 ? '-' : formatMs(r.ms[3]);
      case 'total':
        return formatMs(r.total);
      case 'cpu':
        return a == null || a.cpuMs == 0 ? '-' : formatCpuMs(a.cpuMs);
      case 'ram':
        return a == null || a.ramN == 0 ? '-' : formatKb(a.ramKb);
      case 'peak':
        return a == null || a.peakKb == 0 ? '-' : formatKb(a.peakKb);
      case 'ior':
        return a == null || a.ior == 0 ? '-' : formatBytes(a.ior);
      case 'iow':
        return a == null || a.iow == 0 ? '-' : formatBytes(a.iow);
    }
    return '-';
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
    Hidden.load();
    MetricPrefs.load();
    ColumnPrefs.load();
    loadHaptics();
    Hidden.apps.addListener(onHiddenChanged);
    MetricPrefs.enabled.addListener(onMetricsChanged);
    ColumnPrefs.hidden.addListener(onColumnsChanged);
    refresh();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (++ticks % 20 == 0) requestFlush();
      if (ticks % 21600 == 0) checkForUpdate();
      if (!Platform.isWindows && !Platform.isAndroid && ticks % 3 == 0) posixTouchAlive();
      if (updaterSupported && settings.autoUpdate) pollAction();
      refresh();
    });
  }

  @override
  void dispose() {
    Hidden.apps.removeListener(onHiddenChanged);
    MetricPrefs.enabled.removeListener(onMetricsChanged);
    ColumnPrefs.hidden.removeListener(onColumnsChanged);
    timer?.cancel();
    usage.close();
    super.dispose();
  }

  void onMetricsChanged() {
    if (!mounted) return;
    resSel.retainAll(MetricPrefs.enabled.value);
    final fk = keyOf(from);
    final tk = keyOf(to);
    setState(() {
      resMap = MetricPrefs.enabled.value.any(procMetricIds.contains) ? usage.resources(fk, tk) : {};
      loadChart(force: true);
    });
  }

  void onColumnsChanged() {
    if (mounted) setState(() {});
  }

  void onHiddenChanged() {
    if (!mounted) return;
    if (only != null && Hidden.has(only!)) only = null;
    refresh();
    setState(() => loadChart(force: true));
  }

  Future<void> pollAction() async {
    String? action;
    if (Platform.isAndroid) {
      action = await collector?.bridge.takeAction();
    } else {
      final f = File('${dataDir()}${Platform.pathSeparator}update_request');
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
        action = 'update';
      }
    }
    final pending = update;
    if (pending != null && !pending.ready && readyInstaller(pending.latest) != null && mounted) setState(() => pending.ready = true);
    if (action != 'update' || !mounted || updating) return;
    final info = await checkUpdate();
    if (!mounted || info == null) return;
    setState(() => update = info);
    runUpdate();
  }

  Future<void> checkForUpdate() async {
    if (!updaterSupported || !settings.autoUpdate || updating) return;
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
    buzz(1);
    final ok = await downloadAndInstall(info, (v) {
      if (mounted) setState(() => updateProgress = v);
    });
    buzz(ok ? 2 : 1);
    if (ok && !Platform.isAndroid) exit(0);
    if (mounted) {
      setState(() {
        updating = false;
        updateFailed = !ok;
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
        Text('${tr(info.ready ? 'updateReady' : 'updateAvailable')}: ${info.current} \u2192 ${info.latest}', style: const TextStyle(color: cPrimary, fontWeight: FontWeight.w700)),
        if (updating)
          SizedBox(width: 160, child: LinearProgressIndicator(value: updateProgress > 0 ? updateProgress : null, color: cPrimary, backgroundColor: cBorder))
        else
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 34)),
            onPressed: runUpdate,
            child: Text(tr(info.ready ? 'updateRestart' : 'updateAction')),
          ),
        if (updating) Text(tr('updating'), style: const TextStyle(color: cMuted)),
        if (updateFailed)
          Text(updateNote == 'permission' ? tr('updatePermission') : (updateNote.isEmpty ? tr('updateFailed') : '${tr('updateFailed')} ($updateNote)'), style: const TextStyle(color: cDanger)),
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
      rows = (l ?? usage.range(fk, tk)).where((r) => !Hidden.has(r.app)).toList();
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
        resMap = MetricPrefs.enabled.value.any(procMetricIds.contains) ? usage.resources(fk, tk) : {};
        rangeKey = rk;
      }
    });
  }

  Future<void> pickRange() async {
    final today = dateOnly(DateTime.now());
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: today,
      errorFormatText: tr('dateFormatError'),
      errorInvalidText: tr('dateOutOfRange'),
      errorInvalidRangeText: tr('dateRangeError'),
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
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: today,
      errorFormatText: tr('dateFormatError'),
      errorInvalidText: tr('dateOutOfRange'),
      errorInvalidRangeText: tr('dateRangeError'),
      helpText: tr('exportRange'),
      initialDateRange: DateTimeRange(start: from, end: to.isAfter(today) ? today : to),
    );
    if (picked == null) return null;
    final fk = keyOf(dateOnly(picked.start));
    final tk = keyOf(dateOnly(picked.end));
    requestFlush();
    String q(String v) => '"${v.replaceAll('"', '""')}"';
    final b = StringBuffer('\uFEFF');
    if (multiState) {
      b.writeln('${tr('app')},${tr('focused')} (s),${tr('open')} (s),${tr('minimized')} (s),${tr('background')} (s),${tr('total')} (s)');
    } else {
      b.writeln('${tr('app')},${tr('total')} (s)');
    }
    for (final r in usage.range(fk, tk)) {
      if (multiState) {
        b.writeln('${q(r.title)},${r.ms[0] ~/ 1000},${r.ms[1] ~/ 1000},${r.ms[2] ~/ 1000},${r.ms[3] ~/ 1000},${r.total ~/ 1000}');
      } else {
        b.writeln('${q(r.title)},${r.total ~/ 1000}');
      }
    }
    final fileName = 'wolium_${fk}_$tk.csv';
    if (Platform.isAndroid) {
      return collector?.bridge.saveFile(fileName, utf8.encode(b.toString()));
    }
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    final docs = home == null ? null : '$home${Platform.pathSeparator}Documents';
    final dir = docs != null && Directory(docs).existsSync() ? docs : dataDir();
    final String? path;
    if (Platform.isWindows) {
      path = saveFileDialog(
        title: tr('exportSaveTitle'),
        filter: 'CSV (*.csv)\u0000*.csv\u0000',
        name: fileName,
        ext: 'csv',
        dir: dir,
      );
    } else {
      Directory(dir).createSync(recursive: true);
      path = '$dir${Platform.pathSeparator}$fileName';
    }
    if (path == null) return null;
    File(path).writeAsStringSync(b.toString());
    return path;
  }

  bool get serviceDown {
    final grace = startedAt != null && DateTime.now().difference(startedAt!) < const Duration(seconds: 10);
    if (beat == null) return !grace;
    return beat! > const Duration(seconds: staleSeconds);
  }

  Widget accessBanner() {
    return Container(
      width: double.infinity,
      color: cWarn.withValues(alpha: 0.16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(tr('usageAccess'), style: const TextStyle(color: cWarn, fontWeight: FontWeight.w700)),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 34)),
          onPressed: () => collector?.bridge.openSettings(),
          child: Text(tr('usageAccessGrant')),
        ),
      ]),
    );
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
        case 'cpu':
          return resMap[r.app]?.cpuMs ?? 0;
        case 'ram':
          return resMap[r.app]?.ramKb ?? 0;
        case 'peak':
          return resMap[r.app]?.peakKb ?? 0;
        case 'ior':
          return resMap[r.app]?.ior ?? 0;
        case 'iow':
          return resMap[r.app]?.iow ?? 0;
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
    buzz(1);
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
    return SelectionContainer.disabled(child: chartPanelBody(narrow));
  }

  Widget chartPanelBody(bool narrow) {
    return Panel(
      padding: EdgeInsets.all(narrow ? 12 : 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(tr('chartTitle'), style: const TextStyle(fontWeight: FontWeight.w800)),
          rangeSelect(),
          if (!Platform.isAndroid)
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
        if (!Platform.isAndroid && MetricPrefs.enabled.value.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(tr('resChartTitle'), style: const TextStyle(color: cMuted, fontWeight: FontWeight.w800)),
            for (final id in allMetricIds.where(MetricPrefs.enabled.value.contains))
              MouseRegion(
                onEnter: (_) => seriesFocus.value = id,
                onExit: (_) => seriesFocus.value = null,
                child: FilterChip(
                  label: Text(metricName(id)),
                  selected: resSel.contains(id),
                  selectedColor: metricColor(id).withValues(alpha: 0.28),
                  onSelected: (v) => setState(() => v ? resSel.add(id) : resSel.remove(id)),
                ),
              ),
          ]),
        ],
        const SizedBox(height: 10),
        ActivityChart(first: from, total: dayCount * 86400, contribs: contribs, presence: [for (final r in presenceRows) presenceMark(r)], assetUrl: rpcAssetUrl, only: only, metric: metric, title: titleOf, icon: iconOf, height: narrow ? 220 : 280, onView: onChartView, series: Platform.isAndroid ? const [] : buildSeries(ids: resSel, pts: resPts, sys: sysPts, only: only, skip: Hidden.has)),
      ]),
    );
  }

  Widget wideTable(TextStyle head) {
    Widget hov(String? app, Widget child, {AppUsage? row}) => MouseRegion(
          onEnter: app == null ? null : (_) => setState(() => hoverApp = app),
          onExit: app == null ? null : (_) => setState(() => hoverApp = hoverApp == app ? null : hoverApp),
          child: row == null ? child : GestureDetector(behavior: HitTestBehavior.opaque, onSecondaryTapUp: (d) => rowMenu(row, d.globalPosition), child: child),
        );
    Widget cell(String t, AppUsage row, {TextStyle? style}) => hov(
          row.app,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
            child: EllipsisText(t, style: style),
          ),
          row: row,
        );
    final ids = activeColumns();
    final cols = 1 + ids.length;
    return Table(
      columnWidths: {0: const FlexColumnWidth(3), cols: const FixedColumnWidth(44)},
      children: [
        TableRow(children: [
          sortHead(tr('app'), 'app', head),
          for (final id in ids) sortHead(columnLabel(id), id, head),
          const SizedBox.shrink(),
        ]),
        for (final r in sortedRows())
          TableRow(
            decoration: only == r.app
                ? BoxDecoration(color: cSoft.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(8), border: Border.all(color: cPrimary))
                : BoxDecoration(color: menuApp == r.app ? cSoft.withValues(alpha: 0.7) : (hoverApp == r.app ? cSoft.withValues(alpha: 0.35) : null), border: const Border(top: BorderSide(color: cBorder))),
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => toggleOnly(r.app),
                onSecondaryTapUp: (d) => rowMenu(r, d.globalPosition),
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
              for (final id in ids)
                if (id == 'now') hov(r.app, nowCell(r), row: r) else cell(cellText(id, r), r, style: id == 'total' ? const TextStyle(fontWeight: FontWeight.w800) : null),
              hov(r.app, Align(alignment: Alignment.center, child: hideButton(r)), row: r),
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
        if (liveMode) sortHead(tr('now'), 'now', head),
        sortHead(tr('total'), 'total', head),
        if (multiState) ...[
          sortHead(tr('focused'), 'focused', head),
          sortHead(tr('open'), 'open', head),
        ],
      ]),
      for (final r in sortedRows())
        GestureDetector(
          onTap: () => toggleOnly(r.app),
          onLongPress: Platform.isAndroid ? () => androidMenu(r) : null,
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
              hideButton(r),
            ]),
            if (multiState)
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

  Widget leaderCard() {
    if (rows.isEmpty) return const SizedBox.shrink();
    AppUsage best = rows.first;
    final useFocus = rows.any((r) => r.ms[0] > 0);
    final useVisible = !useFocus && rows.any((r) => r.visible > 0);
    int score(AppUsage r) => useFocus ? r.ms[0] : (useVisible ? r.visible : r.total);
    for (final r in rows) {
      if (score(r) > score(best)) best = r;
    }
    if (score(best) <= 0) return const SizedBox.shrink();
    final label = dayCount > 1 ? tr('leaderPeriod') : tr('leaderDay');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Panel(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(children: [
          AppIcon(title: best.title, path: best.path, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: '$label: ', style: const TextStyle(color: cMuted, fontWeight: FontWeight.w700)),
                TextSpan(text: best.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                TextSpan(text: ' (${formatMs(score(best))})', style: const TextStyle(color: cPrimary, fontWeight: FontWeight.w800)),
              ]),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      ),
    );
  }

  Widget hideButton(AppUsage r) => IconButton(
        tooltip: tr('hideApp'),
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.visibility_off_outlined, size: 18, color: cMuted),
        onPressed: () {
          buzz(1);
          Hidden.hide(r.app, r.title);
        },
      );

  Widget activity(bool narrow) {
    const head = TextStyle(color: cMuted, fontWeight: FontWeight.w800);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      leaderCard(),
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
        body: SafeArea(
          child: Builder(builder: (context) {
            final content = ValueListenableBuilder<bool>(
              valueListenable: chartPinch,
              builder: (context, pinching, _) => column(narrow, title, pad, pinching),
            );
            return Platform.isAndroid ? content : SelectionArea(child: content);
          }),
        ),
      );
    });
  }

  Widget column(bool narrow, String title, double pad, bool pinching) {
    return Column(children: [
          topbar(narrow),
          Expanded(
            child: Row(children: [
              if (!narrow) sidebar(),
              Expanded(
                child: Column(children: [
                  if (update != null) updateBanner(),
                  if (serviceDown) banner() else if (isPaused) pausedBanner(),
                  if (collector != null)
                    ValueListenableBuilder<bool>(
                      valueListenable: collector!.access,
                      builder: (_, ok, __) => ok ? const SizedBox.shrink() : accessBanner(),
                    ),
                  Expanded(
                    child: NotificationListener<ScrollStartNotification>(
                      onNotification: (_) {
                        tipsReset.value++;
                        return false;
                      },
                      child: ListView(physics: pinching ? const NeverScrollableScrollPhysics() : null, padding: EdgeInsets.fromLTRB(pad, pad, pad, 28), children: [
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
                  ),
                ]),
              ),
            ]),
          ),
          if (narrow) bottomNav(),
        ]);
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
  String? backupText;
  String? exportError;
  bool checking = false;
  String deviceLabel = deviceName();
  final metricsUsage = Usage();
  late final List<int> forecastHist = metricsUsage.forecastHistory();
  late final int forecastDisks = metricsUsage.sysDiskCount();
  late bool localApi = prefs.flag('localapi');
  late bool discord = prefs.flag('discordrpc');
  String rpcStatus = '';
  bool rpcRestarting = false;
  Timer? rpcTimer;

  String readRpcStatus() {
    try {
      return File('${dataDir()}${Platform.pathSeparator}discordrpc.status').readAsStringSync().trim();
    } catch (_) {
      return '';
    }
  }

  @override
  void dispose() {
    rpcTimer?.cancel();
    metricsUsage.close();
    super.dispose();
  }

  Future<void> restartRpc() async {
    setState(() => rpcRestarting = true);
    prefs.setFlag('discordrpc', true);
    setState(() => discord = true);
    if (!Platform.isWindows) {
      final found = await restartDiscordPosix();
      if (!mounted) return;
      if (!found) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('rpcNotRunning'))));
      setState(() {
        rpcRestarting = false;
        rpcStatus = readRpcStatus();
      });
      return;
    }
    try {
      final paths = runningDiscordPaths();
      final sep = Platform.pathSeparator;
      String base(String p) => p.split(sep).last;
      for (final exe in paths) {
        await Process.run('taskkill', ['/F', '/T', '/IM', base(exe)]);
      }
      await Future<void>.delayed(const Duration(seconds: 7));
      final local = Platform.environment['LOCALAPPDATA'] ?? '';
      for (final exe in paths) {
        if (File(exe).existsSync()) {
          await Process.start(exe, [], workingDirectory: File(exe).parent.path, mode: ProcessStartMode.detached);
          continue;
        }
        final candidates = [File(exe).parent.parent.path, if (local.isNotEmpty) '$local${sep}Discord'];
        for (final dir in candidates) {
          final updater = File('$dir${sep}Update.exe');
          if (updater.existsSync()) {
            await Process.start(updater.path, ['--processStart', base(exe)], mode: ProcessStartMode.detached);
            break;
          }
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      rpcRestarting = false;
      rpcStatus = readRpcStatus();
    });
  }

  void showRpcHelp() {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('discordRpc')),
        content: Text(tr('rpcRestartHelp')),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('ok')))],
      ),
    );
  }

  int rowsTimeCost(Forecast f) => f.rowsPerDay * forecastDays * timeRowBytes;

  void apiHelp() {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('localApi')),
        content: Text(tr('localApiHint')),
        actions: [
          TextButton(onPressed: () => open('https://github.com/arturwo1/TrackWolium/blob/main/docs/local-api.md'), child: Text(tr('localApiDocs'))),
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('ok'))),
        ],
      ),
    );
  }

  Widget metricsSection() {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: MetricPrefs.enabled,
      builder: (context, en, _) {
        final timeOn = !en.contains('notime');
        final f = forecastDb(enabled: en, timeOn: timeOn, histRows: forecastHist[0], histDays: forecastHist[1], disks: forecastDisks == 0 ? defaultDiskCount : forecastDisks);
        String size(int b) => formatSize(b, sizeUnits());
        Widget row(String id) {
          final on = en.contains(id);
          var cost = f.perMetric[id] ?? 0;
          if (!on && procMetricIds.contains(id) && f.base == 0) cost += baseCost(f.rowsPerDay);
          return Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(metricName(id), style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(tr('metricsPerMonth').replaceAll('{size}', size(cost)), style: const TextStyle(color: cMuted, fontSize: 12)),
              ]),
            ),
            Switch(
              value: on,
              onChanged: (v) {
                buzz(0);
                MetricPrefs.set(id, v);
              },
            ),
          ]);
        }

        return Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Text(tr('metricsTitle'), style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(tr('metricsTotal').replaceAll('{size}', size(f.total)), style: const TextStyle(color: cMuted, fontSize: 12)),
            children: [
              Align(alignment: Alignment.centerLeft, child: Text(tr('metricsHint'), style: const TextStyle(color: cMuted, fontSize: 12))),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('metricsTime'), style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(tr('metricsPerMonth').replaceAll('{size}', size(timeOn ? f.time : rowsTimeCost(f))), style: const TextStyle(color: cMuted, fontSize: 12)),
                  ]),
                ),
                Switch(
                  value: timeOn,
                  onChanged: (v) {
                    buzz(0);
                    MetricPrefs.set('notime', !v);
                  },
                ),
              ]),
              for (final id in allMetricIds) row(id),
              const SizedBox(height: 6),
              Align(alignment: Alignment.centerLeft, child: Text(f.measured ? tr('metricsMeasured') : tr('metricsEstimated'), style: const TextStyle(color: cMuted, fontSize: 12))),
            ],
          ),
        );
      },
    );
  }

  Widget hiddenSection() {
    return ValueListenableBuilder<Map<String, String>>(
      valueListenable: Hidden.apps,
      builder: (context, map, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('hiddenApps'), style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(map.isEmpty ? tr(Platform.isAndroid ? 'hiddenNoneTouch' : 'hiddenNone') : tr('hiddenHint'), style: const TextStyle(color: cMuted, fontSize: 12)),
        for (final e in map.entries)
          Row(children: [
            Expanded(child: EllipsisText(e.value.isEmpty ? prettyApp(e.key) : e.value, style: const TextStyle(fontWeight: FontWeight.w600))),
            TextButton(onPressed: () => Hidden.show(e.key), child: Text(tr('unhide'))),
          ]),
        const Divider(height: 28),
      ]),
    );
  }

  Future<void> renameDevice() async {
    final controller = TextEditingController(text: deviceLabel);
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('thisDevice')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 64,
          decoration: InputDecoration(hintText: tr('deviceNameHint')),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, ''), child: Text(tr('deviceReset'))),
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
          TextButton(onPressed: () => Navigator.pop(c, controller.text), child: Text(tr('save'))),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    saveDeviceName(result);
    if (mounted) setState(() => deviceLabel = deviceName());
  }

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
    if (Platform.isAndroid) collector?.bridge.setApiService(v);
    setState(() => localApi = v);
  }

  @override
  void initState() {
    super.initState();
    rpcStatus = readRpcStatus();
    rpcTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final v = readRpcStatus();
      if (mounted && v != rpcStatus) setState(() => rpcStatus = v);
    });
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
        if (!Platform.isAndroid) ...[
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
        ],
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('thisDevice'), style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(deviceLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: cMuted)),
              Text('${tr('deviceId')}: ${deviceId()}', style: const TextStyle(color: cMuted, fontSize: 12)),
            ]),
          ),
          IconButton(
            tooltip: tr('deviceEdit'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit_outlined, size: 20),
            onPressed: renameDevice,
          ),
        ]),
        const Divider(height: 28),
        if (updaterSupported) ...[
          Row(children: [
            Expanded(child: Text(tr('autoUpdate'), style: const TextStyle(fontWeight: FontWeight.w700))),
            Switch(
              value: autoUpdate,
              onChanged: (v) {
                buzz(0);
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
        ],
        Row(children: [
          Expanded(child: Text(tr('localApi'), style: const TextStyle(fontWeight: FontWeight.w700))),
          Switch(value: localApi, onChanged: toggleApi),
        ]),
        Row(children: [
          Expanded(child: Text(tr('localApiShort'), style: const TextStyle(color: cMuted, fontSize: 12))),
          IconButton(
            tooltip: tr('localApiMore'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.help_outline, size: 18, color: cMuted),
            onPressed: apiHelp,
          ),
        ]),
        if (Platform.isAndroid) Text(tr('localApiAndroid'), style: const TextStyle(color: cMuted, fontSize: 12)),
        const Divider(height: 28),
        if (!Platform.isAndroid) ...[
          Row(children: [
            Expanded(child: Text(tr('discordRpc'), style: const TextStyle(fontWeight: FontWeight.w700))),
            Switch(
              value: discord,
              onChanged: (v) {
                prefs.setFlag('discordrpc', v);
                setState(() => discord = v);
              },
            ),
          ]),
          Text(tr('discordRpcHint'), style: const TextStyle(color: cMuted, fontSize: 12)),
          if (discord) ...[
            const SizedBox(height: 8),
            if (rpcStatus == 'busy')
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: cWarn.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(rSm), border: Border.all(color: cWarn)),
                child: Text(tr('rpcFailed'), style: const TextStyle(color: cWarn, fontWeight: FontWeight.w700)),
              )
            else
              Text(
                rpcStatus == 'active' ? tr('rpcActive') : tr('rpcWaiting'),
                style: TextStyle(color: rpcStatus == 'active' ? cOk : cMuted, fontWeight: FontWeight.w700),
              ),
            const SizedBox(height: 8),
            Row(children: [
              OutlinedButton(onPressed: rpcRestarting ? null : restartRpc, child: Text(rpcRestarting ? tr('rpcRestarting') : tr('rpcRestart'))),
              IconButton(
                tooltip: tr('helpTitle'),
                icon: const Icon(Icons.help_outline, size: 20, color: cMuted),
                onPressed: showRpcHelp,
              ),
            ]),
        ],
        const Divider(height: 28),
        ],
        if (Platform.isAndroid) ...[
          Row(children: [
            Expanded(child: Text(tr('hapticsTitle'), style: const TextStyle(fontWeight: FontWeight.w700))),
            SelectBox<int>(
              value: hapticLevel,
              items: [
                DropdownMenuItem(value: 0, child: Text(tr('hapticsOff'))),
                DropdownMenuItem(value: 1, child: Text(tr('hapticsLight'))),
                DropdownMenuItem(value: 2, child: Text(tr('hapticsMedium'))),
                DropdownMenuItem(value: 3, child: Text(tr('hapticsStrong'))),
              ],
              onChanged: (v) {
                saveHaptics(v ?? 1);
                buzz(1);
                setState(() {});
              },
            ),
          ]),
          const Divider(height: 28),
        ],
        if (!Platform.isAndroid) ...[
          metricsSection(),
          const Divider(height: 28),
        ],
        hiddenSection(),
        Row(children: [
          Expanded(child: Text(tr('language'), style: const TextStyle(fontWeight: FontWeight.w700))),
          LanguagePicker(onChanged: () => setState(() {})),
        ]),
        const Divider(height: 28),
        if (!Platform.isAndroid) ...[
          Text(tr('dataFolder'), style: const TextStyle(color: cMuted, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: SelectableText(dataDir())),
            if (!Platform.isAndroid)
              IconButton(
                tooltip: tr('openFolder'),
                icon: const Icon(Icons.folder_open, size: 18),
                onPressed: () => openPath(dataDir()),
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
        ],
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
        if (Platform.isAndroid && collector != null) ...[
          const Divider(height: 28),
          Text(tr('backupTitle'), style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(tr('backupHint'), style: const TextStyle(color: cMuted, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(spacing: 12, runSpacing: 8, children: [
            OutlinedButton(
              onPressed: () async {
                final r = await saveBackup(collector!.bridge);
                if (mounted && r != null) setState(() => backupText = tr('backupSaved'));
              },
              child: Text(tr('backupSave')),
            ),
            OutlinedButton(
              onPressed: () async {
                final r = await restoreBackup(collector!.bridge);
                if (mounted && r != null) setState(() => backupText = r ? tr('backupRestored') : tr('backupBad'));
              },
              child: Text(tr('backupRestore')),
            ),
          ]),
          if (backupText != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(backupText!, style: const TextStyle(color: cMuted))),
        ],
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
                if (!Platform.isAndroid) OutlinedButton(onPressed: () => openPath(exportedPath!, select: true), child: Text(tr('openFolder'))),
                OutlinedButton(onPressed: () => openPath(exportedPath!), child: Text(tr('openFile'))),
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

String updateStatus() {
  try {
    final f = File('${dataDir()}${Platform.pathSeparator}update.status');
    return f.existsSync() ? f.readAsStringSync().trim() : '';
  } catch (_) {
    return '';
  }
}
