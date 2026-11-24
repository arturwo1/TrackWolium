import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
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
import 'categories_ui.dart';
import 'prefs.dart';
import 'package:path_provider/path_provider.dart';
import 'posix.dart';
import 'haptics.dart';
import 'discord_posix.dart';
import 'p2p_sync.dart';
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
  await P2pSync.instance.startIfEnabled();
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
        builder: (context, child) => DefaultSelectionStyle(
          mouseCursor: SystemMouseCursors.basic,
          child: child ?? const SizedBox.shrink(),
        ),
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
      if (Platform.isAndroid) {
        if (settings.flag('localapi')) collector?.bridge.setApiService(true);
        collector?.bridge.setCrashLogs(!settings.flag('nocrashlogs'));
      }
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
    return selectableRegion(
      Scaffold(
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

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  final usage = Usage();
  Timer? timer;
  int tab = 0;
  List<String> days = [];
  late DateTime from;
  late DateTime to;
  TimeOfDay fromTime = const TimeOfDay(hour: 0, minute: 0);
  TimeOfDay toTime = const TimeOfDay(hour: 23, minute: 59);
  String preset = 'day';
  String? hoverApp;
  bool showTime = true;
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
  List<StatPoint> statPts = [];
  final resSel = <String>{};
  String? catFilter;
  List<Contrib> previous = [];
  Map<String, int> afkMs = {};
  Set<String> rowApps = {};
  bool dirty = false;
  final ScrollController tableHScroll = ScrollController();
  final ScrollController vScroll = ScrollController();
  final GlobalKey chartKey = GlobalKey();
  final FocusNode shellFocus = FocusNode();
  Offset? autoScrollOrigin;
  Offset? autoScrollCursor;
  Timer? autoScrollTimer;
  bool autoScrollMoved = false;
  Set<String> selectedDevices = {'local'};
  List<DeviceInfo> peerDevices = [];
  Map<String, List<SiteUsage>> sitesByBrowser = {};
  List<SiteContrib> siteContribs = [];
  final Set<String> expandedBrowsers = {};
  ActivityStats activityStats = const ActivityStats();
  List<GlobalDeviceStats> globalStats = const [];
  int dataTab = 0;
  String _lastDbSig = '';
  String _cachedSeriesKey = '';
  List<ResSeries> _cachedSeries = const [];

  bool get isLocalOnly => selectedDevices.length == 1 && selectedDevices.contains('local');
  bool get includesLocal => selectedDevices.isEmpty || selectedDevices.contains('local');
  bool get showMultiState => !Platform.isAndroid || !isLocalOnly;

  bool availableBattery() =>
      sysPts.any((p) => p.kind == 'battery') ||
      globalStats.any((g) => g.batteryPct >= 0 || g.batteryDrainTenths > 0) ||
      statPts.any((p) => p.kind == 'battery') ||
      activityStats.batteryTenths.isNotEmpty ||
      Platform.isAndroid ||
      peerDevices.any((d) => d.platform.toLowerCase() == 'android');

  Set<String> availableResourceIds() {
    final out = <String>{
      if (!Platform.isAndroid) ...MetricPrefs.enabled.value,
    };
    if (resMap.values.any((a) => a.cpuMs > 0)) out.add('cpu');
    if (resMap.values.any((a) => a.ramN > 0)) out.add('ram');
    if (resMap.values.any((a) => a.peakKb > 0)) out.add('peak');
    if (resMap.values.any((a) => a.ior > 0)) out.add('ior');
    if (resMap.values.any((a) => a.iow > 0)) out.add('iow');
    if (sysPts.any((p) => p.kind == 'ram')) out.add('sysram');
    if (sysPts.any((p) => p.kind.startsWith('disk:'))) out.add('sysdisk');
    if (sysPts.any((p) => p.kind == 'battery') || globalStats.any((g) => g.batteryPct >= 0) || Platform.isAndroid) {
      out.add('battery');
    }
    return out;
  }
  bool get hasCustomTime => preset == 'custom' && (fromTime.hour != 0 || fromTime.minute != 0 || toTime.hour != 23 || toTime.minute != 59);
  int? get customStartEpoch => !hasCustomTime ? null : DateTime(from.year, from.month, from.day, fromTime.hour, fromTime.minute).millisecondsSinceEpoch ~/ 1000;
  int? get customEndEpoch => !hasCustomTime ? null : DateTime(to.year, to.month, to.day, toTime.hour, toTime.minute).add(const Duration(minutes: 1)).millisecondsSinceEpoch ~/ 1000;
  double? get customChartInitFrom {
    final s = customStartEpoch;
    if (s == null) return null;
    final mid = DateTime(from.year, from.month, from.day).millisecondsSinceEpoch ~/ 1000;
    return math.max(0.0, (s - mid).toDouble());
  }

  double? get customChartInitTo {
    final e = customEndEpoch;
    if (e == null) return null;
    final mid = DateTime(from.year, from.month, from.day).millisecondsSinceEpoch ~/ 1000;
    return math.min(dayCount * 86400.0, (e - mid).toDouble());
  }

  String get deviceFilterKey {
    final list = selectedDevices.toList()..sort();
    return list.join(',');
  }

  bool get realFocusOn => ViewPrefs.realFocus && showMultiState && !MetricPrefs.has('notime');

  DateTime prevFrom() => DateTime(from.year, from.month, from.day - dayCount);

  bool appAllowed(String app) {
    if (Hidden.has(app)) return false;
    final cat = Categories.byId(catFilter);
    if (cat != null && !cat.apps.contains(app)) return false;
    return (ViewPrefs.minSec == 0 && ViewPrefs.maxSec == 0) || rowApps.contains(app);
  }

  List<AppUsage> prepareRows(List<AppUsage> src, String fk, String tk) {
    var list = src.where((r) => !Hidden.has(r.app)).toList();
    final timeOn = (!Platform.isAndroid && !MetricPrefs.has('notime')) || !isLocalOnly;
    final idle = realFocusOn || (timeOn && ColumnPrefs.shown('realcol')) ? usage.afk(fk, tk, devices: selectedDevices) : <String, int>{};
    afkMs = idle;
    if (realFocusOn) {
      list = list.where((r) => r.total > 0).toList();
    }
    if (ViewPrefs.minSec > 0) {
      list = list.where((r) => (r.visible > 0 ? r.visible : r.total) >= ViewPrefs.minSec * 1000).toList();
    }
    if (ViewPrefs.maxSec > 0) {
      list = list.where((r) => (r.visible > 0 ? r.visible : r.total) <= ViewPrefs.maxSec * 1000).toList();
    }
    if (list.isNotEmpty) {
      rowApps = {for (final r in list) r.app};
    } else if (resMap.isNotEmpty) {
      rowApps = {
        for (final e in resMap.entries)
          if (!Hidden.has(e.key) &&
              (ViewPrefs.minSec == 0 || e.value.cpuMs >= ViewPrefs.minSec * 1000) &&
              (ViewPrefs.maxSec == 0 || e.value.cpuMs <= ViewPrefs.maxSec * 1000))
            e.key,
      };
    } else {
      rowApps = {};
    }
    final cat = Categories.byId(catFilter);
    if (cat != null) list = list.where((r) => cat.apps.contains(r.app)).toList();
    return list;
  }

  void onViewChanged() {
    if (!mounted) return;
    if (catFilter != null && Categories.byId(catFilter) == null) catFilter = null;
    dirty = true;
    refresh();
  }

  int get dayCount => DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays + 1;

  void loadChart({bool force = false}) {
    final total = dayCount * 86400;
    final sp = viewTo - viewFrom;
    final useSess = sp <= 7 * 86400;
    final bin = math.max(1, (viewBucket / 300).round());
    final inside = loadW0 >= 0 && viewFrom >= loadW0 && viewTo <= loadW1;
    if (!force && inside && bin == loadBin && useSess == loadSess) return;
    final w0 = math.max(0, viewFrom - sp).floor();
    final w1 = math.min(total.toDouble(), viewTo + sp).ceil();
    final sEp = customStartEpoch;
    final eEp = customEndEpoch;
    contribs = usage.contribs(from, w0, w1, bin, useSess, realFocus: realFocusOn, devices: selectedDevices, startEpoch: sEp, endEpoch: eEp).where((c) => appAllowed(c.app)).toList();
    previous = ViewPrefs.compare ? usage.contribs(prevFrom(), w0, w1, bin, false, realFocus: realFocusOn, devices: selectedDevices).where((c) => appAllowed(c.app)).toList() : [];
    siteContribs = usage.browserContribs(from, w0, w1, bin, devices: selectedDevices, startEpoch: sEp, endEpoch: eEp);
    presenceRows = includesLocal ? usage.presence(from, w0, w1) : [];
    final en = MetricPrefs.enabled.value;
    final wantProc = !isLocalOnly || (!Platform.isAndroid && en.any(procMetricIds.contains));
    final wantSys = !isLocalOnly || (!Platform.isAndroid && en.any(sysMetricIds.contains)) || resSel.contains('battery') || Platform.isAndroid;
    resPts = wantProc ? usage.resPoints(from, w0, w1, bin, devices: selectedDevices, startEpoch: sEp, endEpoch: eEp) : [];
    sysPts = wantSys ? usage.sysPoints(from, w0, w1, devices: selectedDevices, startEpoch: sEp, endEpoch: eEp) : [];
    statPts = resSel.any(statMetricIds.contains) ? usage.statPoints(from, w0, w1, bin, devices: selectedDevices, startEpoch: sEp, endEpoch: eEp) : [];
    _cachedSeriesKey = '';
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
        sortAsc = k == 'app' || k == 'category';
      }
    });
  }

  double resizeStartX = 0;
  double resizeStartW = 0;
  bool resizing = false;

  Widget sortHead(String label, String k, TextStyle head, {bool resize = false}) {
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
    Widget label0 = box;
    if (resize && k != 'app') {
      final inner = box;
      label0 = DragTarget<String>(
        onWillAcceptWithDetails: (d) => d.data != k,
        onAcceptWithDetails: (d) => ColumnPrefs.move(d.data, k, columnChoices()),
        builder: (context, cand, rej) => DecoratedBox(
          decoration: BoxDecoration(border: Border(left: BorderSide(color: cand.isNotEmpty ? cPrimary : Colors.transparent, width: 2))),
          child: Draggable<String>(
            data: k,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: Material(
              color: cPanel,
              elevation: 6,
              borderRadius: BorderRadius.circular(rSm),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Text(label, style: head.copyWith(color: cPrimary))),
            ),
            childWhenDragging: Opacity(opacity: 0.35, child: inner),
            child: inner,
          ),
        ),
      );
    }
    final Widget out = !resize
        ? label0
        : LayoutBuilder(builder: (context, c) {
            return Stack(children: [
              Padding(padding: const EdgeInsets.only(right: 8), child: label0),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: 18,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (d) {
                      resizeStartX = d.globalPosition.dx;
                      resizeStartW = c.maxWidth;
                      resizing = true;
                    },
                    onHorizontalDragUpdate: (d) {
                      final w = (resizeStartW + (d.globalPosition.dx - resizeStartX)).clamp(colMin(k, head), 700.0).toDouble();
                      ColumnPrefs.setWidth(k, w, persist: false);
                    },
                    onHorizontalDragEnd: (_) {
                      resizing = false;
                      ColumnPrefs.persistWidths();
                    },
                    onHorizontalDragCancel: () {
                      resizing = false;
                      ColumnPrefs.persistWidths();
                    },
                    child: const Align(alignment: Alignment.centerRight, child: Padding(padding: EdgeInsets.only(right: 7), child: SizedBox(width: 2, child: ColoredBox(color: cBorder)))),
                  ),
                ),
              ),
            ]);
          });
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: (d) => columnMenu(d.globalPosition),
      child: out,
    );
  }

  List<String> columnChoices() {
    final availRes = availableResourceIds();
    return [
      if (Categories.list.value.isNotEmpty) 'category',
      if (liveMode) 'now',
      if (showMultiState) ...['focused', if ((!Platform.isAndroid && !MetricPrefs.has('notime')) || !isLocalOnly) 'realcol', 'open', 'minimized', 'background'],
      'total',
      'opens',
      if (Platform.isAndroid || peerDevices.isNotEmpty || activityStats.notifs.isNotEmpty) 'notifs',
      if (availableBattery()) 'appbattery',
      if (showMultiState) ...procMetricIds.where(availRes.contains),
    ];
  }

  List<String> activeColumns() => ColumnPrefs.sorted([for (final c in columnChoices()) if (ColumnPrefs.shown(c)) c]);

  int realMs(AppUsage r) => math.max(0, r.ms[0] - (afkMs[r.app] ?? 0));

  String columnLabel(String id) => (id == 'appbattery' || id == 'battery' || procMetricIds.contains(id)) ? metricName(id) : tr(id);

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

  Widget selectableDialog(Widget child) => selectableRegion(child);

  Future<bool> confirmEnd(AppUsage r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: cPanel,
        title: Text(tr('actEnd')),
        content: selectableDialog(Text(tr('actEndConfirm').replaceAll('{app}', r.title))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('cancel'))),
          TextButton(style: TextButton.styleFrom(foregroundColor: cDanger), onPressed: () => Navigator.pop(c, true), child: Text(tr('actEnd'))),
        ],
      ),
    );
    return ok == true;
  }

  AppUsage? _findBrowserRow(String browserId) {
    final low = browserId.toLowerCase();
    for (final r in rows) {
      final b = Usage.browserIdForApp(r.app);
      if (b == low || r.app.toLowerCase().contains(low)) return r;
    }
    return null;
  }

  ({String? exe, String? macApp}) _resolveBrowserLauncher(SiteUsage s, AppUsage? browserRow) {
    if (Platform.isAndroid) return (exe: null, macApp: null);
    if (browserRow != null) {
      if (browserRow.path.isNotEmpty && File(browserRow.path).existsSync()) {
        return (exe: browserRow.path, macApp: browserRow.title);
      }
      if (Platform.isMacOS && browserRow.title.isNotEmpty) {
        return (exe: null, macApp: browserRow.title);
      }
    }
    final bId = (Usage.browserIdForApp(browserRow?.app ?? s.browser) ?? s.browser).toLowerCase();
    for (final t in detectBrowserTargets(usage)) {
      if (t.id == bId || t.name.toLowerCase().contains(bId)) {
        return (exe: t.exe, macApp: t.name);
      }
    }
    return (exe: null, macApp: null);
  }

  Future<void> openSiteDefault(SiteUsage s) async {
    final uri = Uri.tryParse(s.openUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> openSiteInBrowser(SiteUsage s, AppUsage? browserRow) async {
    final uri = Uri.tryParse(s.openUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return;
    final target = _resolveBrowserLauncher(s, browserRow);
    try {
      if ((Platform.isWindows || Platform.isLinux) && target.exe != null && File(target.exe!).existsSync()) {
        await Process.start(target.exe!, [uri.toString()], mode: ProcessStartMode.detached);
        return;
      }
      if (Platform.isMacOS && target.macApp != null && target.macApp!.isNotEmpty) {
        final res = await Process.run('open', ['-a', target.macApp!, uri.toString()]);
        if (res.exitCode == 0) return;
      }
    } catch (_) {}
    await openSiteDefault(s);
  }

  Future<void> openSiteFromChart(SiteUsage s, String? browserApp, Offset? at) async {
    final row = browserApp != null ? rows.cast<AppUsage?>().firstWhere((r) => r?.app == browserApp, orElse: () => null) : _findBrowserRow(s.browser);
    await siteMenu(s, row, at);
  }

  Future<void> siteMenu(SiteUsage s, AppUsage? browserRow, Offset? at) async {
    final target = _resolveBrowserLauncher(s, browserRow);
    final canSame = !Platform.isAndroid && ((target.exe != null && File(target.exe!).existsSync()) || (Platform.isMacOS && (target.macApp?.isNotEmpty ?? false)));
    String? action;
    if (!Platform.isAndroid) {
      final sz = MediaQuery.sizeOf(context);
      final pos = at ?? Offset(sz.width / 2, sz.height / 2);
      Widget item(IconData icon, String text, {bool on = true}) {
        final c = on ? cPrimary : cMuted.withValues(alpha: 0.45);
        return Row(children: [Icon(icon, size: 18, color: on ? cMuted : c), const SizedBox(width: 10), Text(text, style: TextStyle(color: c))]);
      }

      action = await darkMenu<String>(pos, [
        PopupMenuItem<String>(enabled: false, height: 32, child: Text(s.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: cMuted, fontWeight: FontWeight.w800, fontSize: 12))),
        PopupMenuItem<String>(value: 'default', child: item(Icons.open_in_browser, tr('siteOpenDefault'))),
        PopupMenuItem<String>(value: 'same', enabled: canSame, child: item(Icons.launch, tr('siteOpenSameBrowser'), on: canSame)),
        PopupMenuItem<String>(value: 'copy', child: item(Icons.copy, tr('siteCopyUrl'))),
      ]);
    } else {
      action = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: cPanel,
        builder: (c) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            selectableDialog(
              ListTile(
                leading: const Icon(Icons.public, color: cPrimary),
                title: Text(s.displayTitle, style: const TextStyle(fontWeight: FontWeight.w800), maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text('${s.domain} · ${s.openUrl}', style: const TextStyle(color: cMuted, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
            const Divider(height: 1),
            ListTile(leading: const Icon(Icons.open_in_browser), title: Text(tr('siteOpenDefault')), onTap: () => Navigator.pop(c, 'default')),
            if (canSame) ListTile(leading: const Icon(Icons.launch), title: Text(tr('siteOpenSameBrowser')), onTap: () => Navigator.pop(c, 'same')),
            ListTile(leading: const Icon(Icons.copy), title: Text(tr('siteCopyUrl')), onTap: () => Navigator.pop(c, 'copy')),
          ]),
        ),
      );
    }
    switch (action) {
      case 'default':
        await openSiteDefault(s);
        break;
      case 'same':
        await openSiteInBrowser(s, browserRow);
        break;
      case 'copy':
        Clipboard.setData(ClipboardData(text: s.openUrl));
        toast('${tr('urlCopied')}: ${s.openUrl}');
        break;
    }
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
      PopupMenuItem<String>(value: 'cat', child: item(Icons.label_outline, tr('catAssign'))),
      PopupMenuItem<String>(value: 'limit', child: item(Icons.timer_outlined, tr('limitNew'))),
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
      case 'cat':
        await assignCategory(r, at);
        break;
      case 'limit':
        if (!mounted) return;
        await limitDialog(context, app: r.app, title: r.title);
        break;
      case 'hide':
        Hidden.hide(r.app, r.title);
        break;
    }
  }

  Future<void> assignCategory(AppUsage r, Offset? at) async {
    final cats = Categories.list.value;
    final cur = Categories.of(r.app);
    String? v;
    if (at != null) {
      v = await darkMenu<String>(at, [
        for (final c in cats)
          PopupMenuItem<String>(value: c.id, child: Row(children: [c.iconWidget(18), const SizedBox(width: 10), Expanded(child: Text(c.name, style: const TextStyle(color: cPrimary))), if (cur?.id == c.id) const Icon(Icons.check, size: 16, color: cPrimary)])),
        if (cats.isNotEmpty) const PopupMenuDivider(),
        if (cur != null) PopupMenuItem<String>(value: '-', child: Text(tr('catRemove'), style: const TextStyle(color: cPrimary))),
        PopupMenuItem<String>(value: '+', child: Text(tr('catNew'), style: const TextStyle(color: cPrimary))),
      ]);
    } else {
      v = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: cPanel,
        builder: (c) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            for (final cat in cats) ListTile(leading: cat.iconWidget(24), title: Text(cat.name), trailing: cur?.id == cat.id ? const Icon(Icons.check) : null, onTap: () => Navigator.pop(c, cat.id)),
            if (cur != null) ListTile(leading: const Icon(Icons.label_off_outlined), title: Text(tr('catRemove')), onTap: () => Navigator.pop(c, '-')),
            ListTile(leading: const Icon(Icons.add), title: Text(tr('catNew')), onTap: () => Navigator.pop(c, '+')),
          ]),
        ),
      );
    }
    if (v == null || !mounted) return;
    if (v == '+') {
      await categoryEditor(context, bridge: collector?.bridge, onCreated: (c) => Categories.assign(r.app, c.id));
    } else {
      Categories.assign(r.app, v == '-' ? null : v);
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
          ListTile(leading: const Icon(Icons.label_outline), title: Text(tr('catAssign')), onTap: () => Navigator.pop(c, 'cat')),
          ListTile(leading: const Icon(Icons.timer_outlined), title: Text(tr('limitNew')), onTap: () => Navigator.pop(c, 'limit')),
          ListTile(leading: const Icon(Icons.visibility_off_outlined), title: Text(tr('actHide')), onTap: () => Navigator.pop(c, 'hide')),
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
      case 'cat':
        await assignCategory(r, null);
        break;
      case 'limit':
        if (!mounted) return;
        await limitDialog(context, app: r.app, title: r.title);
        break;
      case 'hide':
        Hidden.hide(r.app, r.title);
        break;
    }
  }

  String cellText(String id, AppUsage r) {
    final a = resMap[r.app];
    switch (id) {
      case 'focused':
        return r.ms[0] == 0 ? '-' : formatMs(r.ms[0]);
      case 'realcol':
        return realMs(r) == 0 ? '-' : formatMs(realMs(r));
      case 'open':
        return r.ms[1] == 0 ? '-' : formatMs(r.ms[1]);
      case 'minimized':
        return r.ms[2] == 0 ? '-' : formatMs(r.ms[2]);
      case 'background':
        return r.ms[3] == 0 ? '-' : formatMs(r.ms[3]);
      case 'category':
        return Categories.of(r.app)?.name ?? '-';
      case 'total':
        return formatMs(r.total);
      case 'opens':
        final n = activityStats.opens[r.app] ?? 0;
        return n == 0 ? '-' : '$n';
      case 'notifs':
        final n = activityStats.notifs[r.app] ?? 0;
        return n == 0 ? '-' : '$n';
      case 'appbattery':
        final bt = activityStats.batteryTenths[r.app] ?? 0;
        return bt == 0 ? '-' : '${(bt / 10).toStringAsFixed(1)}%';
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
    WidgetsBinding.instance.addObserver(this);
    autostartEnabled();
    to = dateOnly(DateTime.now());
    from = to;
    requestFlush();
    checkForUpdate();
    Hidden.load();
    MetricPrefs.load();
    ColumnPrefs.load();
    ViewPrefs.load();
    Categories.load();
    LimitPrefs.load();
    loadHaptics();
    Hidden.apps.addListener(onHiddenChanged);
    MetricPrefs.enabled.addListener(onMetricsChanged);
    ColumnPrefs.hidden.addListener(onColumnsChanged);
    ViewPrefs.rev.addListener(onViewChanged);
    Categories.list.addListener(onViewChanged);
    P2pSync.instance.version.addListener(onViewChanged);
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      P2pSync.instance.suspendForBackground();
    } else if (state == AppLifecycleState.resumed) {
      P2pSync.instance.resumeFromBackground();
      requestFlush();
      refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    autoScrollTimer?.cancel();
    Hidden.apps.removeListener(onHiddenChanged);
    MetricPrefs.enabled.removeListener(onMetricsChanged);
    ColumnPrefs.hidden.removeListener(onColumnsChanged);
    ViewPrefs.rev.removeListener(onViewChanged);
    Categories.list.removeListener(onViewChanged);
    P2pSync.instance.version.removeListener(onViewChanged);
    tableHScroll.dispose();
    vScroll.dispose();
    shellFocus.dispose();
    timer?.cancel();
    usage.close();
    super.dispose();
  }

  void onMetricsChanged() {
    if (!mounted) return;
    resSel.removeWhere((id) => id != 'battery' && !statMetricIds.contains(id) && !MetricPrefs.enabled.value.contains(id) && !availableResourceIds().contains(id));
    dirty = true;
    final fk = keyOf(from);
    final tk = keyOf(to);
    setState(() {
      resMap = (!Platform.isAndroid && MetricPrefs.enabled.value.any(procMetricIds.contains)) || !isLocalOnly
          ? usage.resources(fk, tk, devices: selectedDevices)
          : {};
      loadChart(force: true);
    });
  }

  void onColumnsChanged() {
    if (mounted) setState(() {});
  }

  void onHiddenChanged() {
    if (!mounted) return;
    if (only != null && Hidden.has(only!)) only = null;
    dirty = true;
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
        if (!Platform.isAndroid && settings.flag('localapi'))
          Text(tr('updateExtNotice'), style: const TextStyle(color: cMuted, fontSize: 12)),
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
    fromTime = const TimeOfDay(hour: 0, minute: 0);
    toTime = const TimeOfDay(hour: 23, minute: 59);
  }

  String _computeDbSig(String rk) {
    String fileSig(String path) {
      try {
        final s = File(path).statSync();
        return '${s.modified.microsecondsSinceEpoch}:${s.size}';
      } catch (_) {
        return '-';
      }
    }
    return '$rk|${fileSig(dbPath())}|${fileSig('${dbPath()}-wal')}|${P2pSync.instance.version.value}|${ViewPrefs.rev.value}|${Hidden.apps.value.length}|${Categories.list.value.length}|${MetricPrefs.enabled.value.length}';
  }

  void refresh() {
    if (preset != 'custom') applyPreset(preset);
    final today = dateOnly(DateTime.now());
    final fk = keyOf(from);
    final tk = keyOf(to);
    final sEp = customStartEpoch;
    final eEp = customEndEpoch;
    final latestPeers = usage.devices();
    final validIds = {'local', for (final d in latestPeers) d.id};
    selectedDevices.removeWhere((id) => !validIds.contains(id));
    if (selectedDevices.isEmpty) selectedDevices.add('local');
    final b = usage.sinceHeartbeat();
    final up = b != null && b <= const Duration(seconds: staleSeconds);
    final l = isLocalOnly && up && !hasCustomTime && from == to && to == today ? usage.live() : null;
    final rk = '$fk|$tk|${sEp ?? ''}|${eEp ?? ''}|$deviceFilterKey';
    final sig = _computeDbSig(rk);
    final dbAvailable = usage.available;
    final pausedNow = usage.paused;
    final wasUp = beat != null && beat! <= const Duration(seconds: staleSeconds);
    final changed = rangeKey != rk;
    final dbModified = sig != _lastDbSig;
    if (!changed && !dirty && !dbModified && l == null && dbAvailable == hasDb && up == wasUp && pausedNow == isPaused && latestPeers.length == peerDevices.length && !liveMode) {
      beat = b;
      return;
    }

    final src = l ?? usage.range(fk, tk, devices: selectedDevices, startEpoch: sEp, endEpoch: eEp);
    if (changed || dirty || dbModified || l != null) {
      final paths = {for (final r in src) if (r.visible > 0 || Platform.isAndroid || !isLocalOnly) r.app: r.path};
      final titles = {for (final r in src) r.app: r.title};
      if (changed || ticks % 30 == 0) {
        final all = usage.names(devices: selectedDevices);
        final real = Platform.isAndroid || !isLocalOnly ? all.keys.toSet() : usage.windowed();
        for (final e in all.entries) {
          if (real.contains(e.key)) paths.putIfAbsent(e.key, () => e.value.path);
          titles.putIfAbsent(e.key, () => e.value.name);
        }
        Categories.autoAssign(paths, sys: Platform.isAndroid ? usage.appCats() : const {}, titles: titles, windowed: real);
      } else {
        Categories.autoAssign(paths, titles: titles);
      }
    }
    setState(() {
      hasDb = dbAvailable;
      peerDevices = latestPeers;
      beat = b;
      isPaused = pausedNow;
      liveMode = l != null;
      final every = dayCount > 1 ? 30 : 5;
      if (changed) {
        viewFrom = customChartInitFrom ?? 0;
        viewTo = customChartInitTo ?? dayCount * 86400.0;
        viewBucket = bucketSecFor(viewTo - viewFrom, 600);
      }
      final reloadHeavy = changed || dirty || (dbModified && (dayCount == 1 || ticks % every == 0)) || (l != null && ticks % every == 0);
      if (reloadHeavy) {
        dirty = false;
        _lastDbSig = sig;
        days = usage.days();
        names = usage.names(devices: selectedDevices);
        sitesByBrowser = usage.browserSites(fk, tk, devices: selectedDevices, startEpoch: sEp, endEpoch: eEp);
        activityStats = usage.activityStats(fk, tk, devices: selectedDevices, startEpoch: sEp, endEpoch: eEp);
        resMap = (!Platform.isAndroid && MetricPrefs.enabled.value.any(procMetricIds.contains)) || !isLocalOnly
            ? usage.resources(fk, tk, devices: selectedDevices)
            : {};
        globalStats = usage.globalStats(fk, tk, devices: selectedDevices, startEpoch: sEp, endEpoch: eEp, localName: deviceName(), localPlatform: Platform.operatingSystem);
        rows = prepareRows(src, fk, tk);
        loadChart(force: true);
        rangeKey = rk;
      } else {
        rows = prepareRows(src, fk, tk);
      }
    });
  }

  Future<({DateTime from, DateTime to, TimeOfDay fromTime, TimeOfDay toTime})?> pickDateTimeRange(
    DateTime initFrom,
    DateTime initTo,
    TimeOfDay initFromTime,
    TimeOfDay initToTime, {
    String? titleText,
  }) async {
    final today = dateOnly(DateTime.now());
    var dFrom = initFrom.isAfter(today) ? today : initFrom;
    var dTo = initTo.isAfter(today) ? today : initTo;
    if (dTo.isBefore(dFrom)) dTo = dFrom;
    final fHCtl = TextEditingController(text: two(initFromTime.hour));
    final fMCtl = TextEditingController(text: two(initFromTime.minute));
    final tHCtl = TextEditingController(text: two(initToTime.hour));
    final tMCtl = TextEditingController(text: two(initToTime.minute));

    TimeOfDay readTime(TextEditingController hc, TextEditingController mc, TimeOfDay fallback) {
      final h = int.tryParse(hc.text.trim()) ?? fallback.hour;
      final m = int.tryParse(mc.text.trim()) ?? fallback.minute;
      return TimeOfDay(hour: h.clamp(0, 23).toInt(), minute: m.clamp(0, 59).toInt());
    }

    final res = await showDialog<({DateTime from, DateTime to, TimeOfDay fromTime, TimeOfDay toTime})>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setDlg) {
          void applyQuick(DateTime a, DateTime b, TimeOfDay ta, TimeOfDay tb) {
            setDlg(() {
              dFrom = a;
              dTo = b;
              fHCtl.text = two(ta.hour);
              fMCtl.text = two(ta.minute);
              tHCtl.text = two(tb.hour);
              tMCtl.text = two(tb.minute);
            });
          }

          Widget timeField(TextEditingController ctl, int maxVal) => SizedBox(
                width: 48,
                child: TextField(
                  controller: ctl,
                  keyboardType: TextInputType.number,
                  maxLength: 2,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(isDense: true, counterText: ''),
                  onChanged: (_) => setDlg(() {}),
                ),
              );

          Future<void> editClock(bool start) async {
            final cur = start ? readTime(fHCtl, fMCtl, initFromTime) : readTime(tHCtl, tMCtl, initToTime);
            final picked = await showTimePicker(
              context: c,
              initialTime: cur,
              builder: (ctx, child) => MediaQuery(data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true), child: child!),
            );
            if (picked == null) return;
            setDlg(() {
              if (start) {
                fHCtl.text = two(picked.hour);
                fMCtl.text = two(picked.minute);
              } else {
                tHCtl.text = two(picked.hour);
                tMCtl.text = two(picked.minute);
              }
            });
          }

          final ft = readTime(fHCtl, fMCtl, initFromTime);
          final tt = readTime(tHCtl, tMCtl, initToTime);
          final startDt = DateTime(dFrom.year, dFrom.month, dFrom.day, ft.hour, ft.minute);
          final endDt = DateTime(dTo.year, dTo.month, dTo.day, tt.hour, tt.minute);
          final valid = !endDt.isBefore(startDt);

          return AlertDialog(
            backgroundColor: cPanel,
            title: Text(titleText ?? tr('rangeDialogTitle')),
            content: SizedBox(
              width: 390,
              child: selectableDialog(
                SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      ActionChip(
                        label: Text(tr('rangeFullDay'), style: const TextStyle(fontSize: 12)),
                        onPressed: () => applyQuick(dFrom, dTo, const TimeOfDay(hour: 0, minute: 0), const TimeOfDay(hour: 23, minute: 59)),
                      ),
                      ActionChip(
                        label: Text(tr('rangeWorkDay'), style: const TextStyle(fontSize: 12)),
                        onPressed: () => applyQuick(dFrom, dTo, const TimeOfDay(hour: 9, minute: 0), const TimeOfDay(hour: 18, minute: 0)),
                      ),
                      ActionChip(
                        label: Text(tr('rangeLastHour'), style: const TextStyle(fontSize: 12)),
                        onPressed: () {
                          final now = DateTime.now();
                          final prev = now.subtract(const Duration(hours: 1));
                          applyQuick(dateOnly(prev), dateOnly(now), TimeOfDay.fromDateTime(prev), TimeOfDay.fromDateTime(now));
                        },
                      ),
                    ]),
                    const SizedBox(height: 12),
                    Text(tr('rangeFromLabel'), style: const TextStyle(color: cMuted, fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Row(children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.calendar_today, size: 15),
                        label: Text(shown(dFrom)),
                        onPressed: () async {
                          final picked = await showDateRangePicker(
                            context: c,
                            firstDate: DateTime(2000),
                            lastDate: today,
                            errorFormatText: tr('dateFormatError'),
                            errorInvalidText: tr('dateOutOfRange'),
                            errorInvalidRangeText: tr('dateRangeError'),
                            initialDateRange: DateTimeRange(start: dFrom, end: dTo),
                          );
                          if (picked != null) {
                            setDlg(() {
                              dFrom = dateOnly(picked.start);
                              dTo = dateOnly(picked.end);
                            });
                          }
                        },
                      ),
                      const SizedBox(width: 10),
                      timeField(fHCtl, 23),
                      const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Text(':', style: TextStyle(fontWeight: FontWeight.w900))),
                      timeField(fMCtl, 59),
                      IconButton(
                        tooltip: tr('pickTime'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.access_time, size: 18, color: cPrimary),
                        onPressed: () => editClock(true),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    Text(tr('rangeToLabel'), style: const TextStyle(color: cMuted, fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Row(children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.calendar_today, size: 15),
                        label: Text(shown(dTo)),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: c,
                            initialDate: dTo,
                            firstDate: dFrom,
                            lastDate: today,
                          );
                          if (picked != null) {
                            setDlg(() => dTo = dateOnly(picked));
                          }
                        },
                      ),
                      const SizedBox(width: 10),
                      timeField(tHCtl, 23),
                      const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Text(':', style: TextStyle(fontWeight: FontWeight.w900))),
                      timeField(tMCtl, 59),
                      IconButton(
                        tooltip: tr('pickTime'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.access_time, size: 18, color: cPrimary),
                        onPressed: () => editClock(false),
                      ),
                    ]),
                    if (!valid)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(tr('dateRangeError'), style: const TextStyle(color: cDanger, fontSize: 12, fontWeight: FontWeight.w700)),
                      ),
                  ]),
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
              FilledButton(
                onPressed: !valid
                    ? null
                    : () => Navigator.pop(c, (from: dFrom, to: dTo, fromTime: ft, toTime: tt)),
                child: Text(tr('ok')),
              ),
            ],
          );
        },
      ),
    );
    fHCtl.dispose();
    fMCtl.dispose();
    tHCtl.dispose();
    tMCtl.dispose();
    return res;
  }

  Future<void> pickRange() async {
    final picked = await pickDateTimeRange(from, to, fromTime, toTime);
    if (picked == null) return;
    setState(() {
      preset = 'custom';
      from = picked.from;
      to = picked.to;
      fromTime = picked.fromTime;
      toTime = picked.toTime;
    });
    requestFlush();
    refresh();
  }

  Widget rangeSelect() {
    final customLabel = preset != 'custom'
        ? tr('presetCustom')
        : (hasCustomTime
            ? '${shown(from)} ${two(fromTime.hour)}:${two(fromTime.minute)} - ${shown(to)} ${two(toTime.hour)}:${two(toTime.minute)}'
            : '${shown(from)} - ${shown(to)}');
    return SelectBox<String>(
      value: preset,
      items: [
        DropdownMenuItem(value: 'day', child: Text(tr('presetDay'))),
        DropdownMenuItem(value: 'week', child: Text(tr('presetWeek'))),
        DropdownMenuItem(value: 'month', child: Text(tr('presetMonth'))),
        DropdownMenuItem(value: 'year', child: Text(tr('presetYear'))),
        DropdownMenuItem(value: 'custom', child: Text(customLabel)),
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

  List<String> exportChoicesFor(Set<String> expDevices) {
    final hasMulti = !Platform.isAndroid || expDevices.any((d) => d != 'local');
    final hasBat = Platform.isAndroid ||
        activityStats.batteryTenths.isNotEmpty ||
        globalStats.any((g) => g.batteryPct >= 0 || g.batteryDrainTenths > 0) ||
        expDevices.any((id) => peerDevices.any((d) => d.id == id && d.platform.toLowerCase() == 'android'));
    return hasMulti
        ? ['focused', 'realcol', 'open', 'minimized', 'background', 'total', 'opens', if (Platform.isAndroid || peerDevices.isNotEmpty || activityStats.notifs.isNotEmpty) 'notifs', if (hasBat) 'appbattery', 'category', ...procMetricIds]
        : ['total', 'opens', 'notifs', if (hasBat) 'appbattery', 'category'];
  }

  Future<({Set<String> cols, String browserMode, Set<String> devices, String format})?> exportColumnsDialog() {
    final expDevices = Set<String>.of(selectedDevices);
    if (expDevices.isEmpty) expDevices.add('local');
    final initChoices = exportChoicesFor(expDevices);
    final picked = <String>{for (final id in activeColumns()) if (initChoices.contains(id)) id, if (Categories.list.value.isNotEmpty) 'category'};
    if (picked.isEmpty) picked.add('total');
    var browserMode = 'apps';
    var format = 'summary';
    return showDialog<({Set<String> cols, String browserMode, Set<String> devices, String format})>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) {
          final choices = exportChoicesFor(expDevices);
          final pickedValid = [for (final id in choices) if (picked.contains(id)) id];
          return AlertDialog(
          backgroundColor: cPanel,
          title: Text(tr('exportWhat')),
          content: SizedBox(
            width: 400,
            child: selectableDialog(
              SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('exportFormatTitle'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  const SizedBox(height: 4),
                  for (final f in const ['summary', 'timesheet']) ...[
                    Builder(builder: (_) {
                      final fk = f == 'summary' ? 'exportFormatSummary' : 'exportFormatTimesheet';
                      return InkWell(
                        onTap: () => set(() => format = f),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(children: [
                            Icon(format == f ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18, color: format == f ? cPrimary : cMuted),
                            const SizedBox(width: 10),
                            Expanded(child: Text(tr(fk), style: TextStyle(color: format == f ? cPrimary : cMuted, fontSize: 13, fontWeight: FontWeight.w600))),
                          ]),
                        ),
                      );
                    }),
                  ],
                  if (peerDevices.isNotEmpty) ...[
                    const Divider(height: 18),
                    Text(tr('exportDevices'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                    const SizedBox(height: 4),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: expDevices.contains('local'),
                      title: Text('${deviceName()} (${tr('devThisTag')})'),
                      onChanged: (v) => set(() {
                        if (v == true) {
                          expDevices.add('local');
                        } else if (expDevices.length > 1) {
                          expDevices.remove('local');
                        }
                      }),
                    ),
                    for (final d in peerDevices)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: expDevices.contains(d.id),
                        title: Text(d.name),
                        onChanged: (v) => set(() {
                          if (v == true) {
                            expDevices.add(d.id);
                          } else if (expDevices.length > 1) {
                            expDevices.remove(d.id);
                          }
                        }),
                      ),
                  ],
                  if (format == 'summary') ...[
                    const Divider(height: 18),
                    Wrap(spacing: 8, children: [
                      OutlinedButton(
                        onPressed: () => set(() {
                          picked
                            ..clear()
                            ..addAll([for (final id in activeColumns()) if (choices.contains(id)) id])
                            ..add('category');
                        }),
                        child: Text(tr('exportVisible')),
                      ),
                      OutlinedButton(
                        onPressed: () => set(() {
                          picked
                            ..clear()
                            ..addAll(choices);
                        }),
                        child: Text(tr('exportAll')),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    for (final id in choices)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: picked.contains(id),
                        title: Text(columnLabel(id)),
                        onChanged: (v) => set(() => v == true ? picked.add(id) : picked.remove(id)),
                      ),
                    const Divider(height: 18),
                    Text(tr('exportBrowserMode'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                    const SizedBox(height: 4),
                    for (final m in const ['apps', 'both', 'sites']) ...[
                      Builder(builder: (_) {
                        final modeKey = m == 'apps' ? 'exportModeApps' : (m == 'both' ? 'exportModeBoth' : 'exportModeSites');
                        return InkWell(
                          onTap: () => set(() => browserMode = m),
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(children: [
                              Icon(browserMode == m ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18, color: browserMode == m ? cPrimary : cMuted),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  tr(modeKey),
                                  style: TextStyle(color: browserMode == m ? cPrimary : cMuted, fontSize: 13, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ]),
                          ),
                        );
                      }),
                    ],
                  ],
                ]),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
            TextButton(
              onPressed: (format == 'summary' && pickedValid.isEmpty)
                  ? null
                  : () => Navigator.pop(c, (cols: Set<String>.of(pickedValid), browserMode: browserMode, devices: Set<String>.of(expDevices), format: format)),
              child: Text(tr('exportCsv')),
            ),
          ],
        );
        },
      ),
    );
  }

  Future<String?> exportCsv() async {
    final picked = await pickDateTimeRange(from, to, fromTime, toTime, titleText: tr('exportRange'));
    if (picked == null) return null;
    final fk = keyOf(picked.from);
    final tk = keyOf(picked.to);
    final customT = picked.fromTime.hour != 0 || picked.fromTime.minute != 0 || picked.toTime.hour != 23 || picked.toTime.minute != 59;
    final sEp = customT ? DateTime(picked.from.year, picked.from.month, picked.from.day, picked.fromTime.hour, picked.fromTime.minute).millisecondsSinceEpoch ~/ 1000 : null;
    final eEp = customT ? DateTime(picked.to.year, picked.to.month, picked.to.day, picked.toTime.hour, picked.toTime.minute).add(const Duration(minutes: 1)).millisecondsSinceEpoch ~/ 1000 : null;
    final resDlg = await exportColumnsDialog();
    if (resDlg == null) return null;
    final expDevices = resDlg.devices;
    final format = resDlg.format;
    requestFlush();
    String q(String v) => '"${v.replaceAll('"', '""')}"';
    final peerMap = {for (final d in peerDevices) d.id: d.name};
    String devLabel(String id) => id == 'local' ? deviceName() : (peerMap[id] ?? id);
    String fmtTs(int sec) {
      final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
      return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
    }

    final b = StringBuffer('\uFEFF');
    if (format == 'timesheet') {
      final rangeStart = sEp ?? DateTime(picked.from.year, picked.from.month, picked.from.day).millisecondsSinceEpoch ~/ 1000;
      final rangeEnd = eEp ?? DateTime(picked.to.year, picked.to.month, picked.to.day).add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000;
      final devNames = {for (final id in expDevices) id: usage.names(devices: {id})};
      b.writeln([
        tr('exportColStart'),
        tr('exportColEnd'),
        '${tr('exportColDuration')} (s)',
        tr('app'),
        tr('exportColState'),
        tr('category'),
        tr('exportColDevice'),
      ].join(','));
      for (final s in usage.sessionsRange(rangeStart, rangeEnd, devices: expDevices)) {
        final appMeta = devNames[s.device]?[s.app];
        final appTitle = (appMeta?.name.isNotEmpty ?? false) ? appMeta!.name : prettyApp(s.app);
        final catName = Categories.of(s.app)?.name ?? '';
        b.writeln([
          q(fmtTs(s.start)),
          q(fmtTs(s.stop)),
          '${s.stop - s.start}',
          q(appTitle),
          q(stateText(s.state)),
          q(catName),
          q(devLabel(s.device)),
        ].join(','));
      }
    } else {
      final cols = resDlg.cols;
      if (cols.isEmpty) return null;
      final browserMode = resDlg.browserMode;
      final idleByDev = cols.contains('realcol')
          ? {for (final id in expDevices) id: usage.afk(fk, tk, devices: {id})}
          : <String, Map<String, int>>{};
      final resByDev = cols.any(procMetricIds.contains)
          ? {for (final id in expDevices) id: usage.resources(fk, tk, devices: {id})}
          : <String, Map<String, ResAgg>>{};
      final wbByDev = <String, ActivityStats>{
        if (cols.contains('opens') || cols.contains('notifs') || cols.contains('appbattery'))
          for (final id in expDevices) id: usage.activityStats(fk, tk, devices: {id}, startEpoch: sEp, endEpoch: eEp),
      };
      final sitesByDev = browserMode == 'apps' ? const <String, Map<String, List<SiteUsage>>>{} : usage.browserSitesByDevice(fk, tk, devices: expDevices, startEpoch: sEp, endEpoch: eEp);
      String unit(String id) {
        if (id == 'category' || id == 'opens' || id == 'notifs') return '';
        if (id == 'appbattery') return ' (%)';
        if (id == 'cpu') return ' (s)';
        if (id == 'ram' || id == 'peak') return ' (KB)';
        if (id == 'ior' || id == 'iow') return ' (B)';
        return ' (s)';
      }

      String value(String id, AppUsage r, String devId) {
        final a = resByDev[devId]?[r.app];
        final wb = wbByDev[devId];
        switch (id) {
          case 'focused':
            return '${r.ms[0] ~/ 1000}';
          case 'realcol':
            return '${math.max(0, r.ms[0] - (idleByDev[devId]?[r.app] ?? 0)) ~/ 1000}';
          case 'open':
            return '${r.ms[1] ~/ 1000}';
          case 'minimized':
            return '${r.ms[2] ~/ 1000}';
          case 'background':
            return '${r.ms[3] ~/ 1000}';
          case 'total':
            return '${r.total ~/ 1000}';
          case 'opens':
            return '${wb?.opens[r.app] ?? 0}';
          case 'notifs':
            return '${wb?.notifs[r.app] ?? 0}';
          case 'appbattery':
            final bt = wb?.batteryTenths[r.app] ?? 0;
            return bt == 0 ? '0' : (bt / 10).toStringAsFixed(1);
          case 'category':
            return q(Categories.of(r.app)?.name ?? '');
          case 'cpu':
            return a == null ? '' : '${a.cpuMs ~/ 1000}';
          case 'ram':
            return a == null || a.ramN == 0 ? '' : '${a.ramKb}';
          case 'peak':
            return a == null ? '' : '${a.peakKb}';
          case 'ior':
            return a == null ? '' : '${a.ior}';
          case 'iow':
            return a == null ? '' : '${a.iow}';
        }
        return '';
      }

      String siteValue(String id, SiteUsage s, String catName) {
        switch (id) {
          case 'focused':
          case 'total':
            return '${s.ms ~/ 1000}';
          case 'category':
            return q(catName);
          default:
            return '';
        }
      }

      String siteCsvLabel(SiteUsage s, {String prefix = '', String suffix = ''}) {
        final t = s.displayTitle;
        final core = t == s.domain ? s.domain : '$t (${s.domain})';
        return '$prefix$core$suffix';
      }

      final ids = [for (final id in exportChoicesFor(expDevices)) if (cols.contains(id)) id];
      b.writeln([tr('app'), tr('exportColDevice'), for (final id in ids) '${columnLabel(id)}${unit(id)}'].join(','));
      for (final dRow in usage.rangeByDevice(fk, tk, devices: expDevices, startEpoch: sEp, endEpoch: eEp)) {
        final r = dRow.usage;
        final dName = devLabel(dRow.device);
        final bId = Usage.browserIdForApp(r.app);
        final sites = bId == null ? const <SiteUsage>[] : (sitesByDev[dRow.device]?[bId] ?? const <SiteUsage>[]);
        final catName = Categories.of(r.app)?.name ?? '';
        if (browserMode == 'sites' && sites.isNotEmpty) {
          for (final s in sites) {
            b.writeln([q(siteCsvLabel(s, suffix: ' — ${r.title}')), q(dName), for (final id in ids) siteValue(id, s, catName)].join(','));
          }
        } else {
          b.writeln([q(r.title), q(dName), for (final id in ids) value(id, r, dRow.device)].join(','));
          if (browserMode == 'both' && sites.isNotEmpty) {
            for (final s in sites) {
              b.writeln([q(siteCsvLabel(s, prefix: '  • ')), q(dName), for (final id in ids) siteValue(id, s, catName)].join(','));
            }
          }
        }
      }
    }
    final fileName = format == 'timesheet' ? 'wolium_${fk}_${tk}_timesheet.csv' : 'wolium_${fk}_$tk.csv';
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

  int metricValue(AppUsage r) => (metric == Metric.focused && realFocusOn) ? realMs(r) : metricOf(r.ms, metric);

  List<AppUsage> sortedRows() {
    final list = List<AppUsage>.from(rows);
    int val(AppUsage r) {
      switch (sortKey) {
        case 'focused':
          return r.ms[0];
        case 'realcol':
          return realMs(r);
        case 'open':
          return r.ms[1];
        case 'minimized':
          return r.ms[2];
        case 'background':
          return r.ms[3];
        case 'total':
          return r.total;
        case 'opens':
          return activityStats.opens[r.app] ?? 0;
        case 'notifs':
          return activityStats.notifs[r.app] ?? 0;
        case 'appbattery':
          return activityStats.batteryTenths[r.app] ?? 0;
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
      if (sortKey == 'category') {
        final c = (Categories.of(a.app)?.name ?? '\uFFFF').toLowerCase().compareTo((Categories.of(b.app)?.name ?? '\uFFFF').toLowerCase());
        return c != 0 ? (sortAsc ? c : -c) : b.total.compareTo(a.total);
      }
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
        content: selectableDialog(
          SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('helpWhat')),
              const SizedBox(height: 12),
              Text(tr('helpMouse'), style: const TextStyle(color: cMuted)),
              const SizedBox(height: 8),
              Text(tr('helpTouch'), style: const TextStyle(color: cMuted)),
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('ok')))],
      ),
    );
  }

  Widget chartPanel(bool narrow) {
    return chartPanelBody(narrow);
  }

  String chartHeading() {
    if (showTime) {
      switch (metric) {
        case Metric.focused:
          return tr('chartTitle');
        case Metric.open:
          return tr('chartTitleOpen');
        case Metric.minimized:
          return tr('chartTitleMin');
        case Metric.visible:
          return tr('chartTitleVisible');
      }
    }
    final avail = availableResourceIds();
    final ids = [
      for (final id in statMetricIds) if (resSel.contains(id)) id,
      if (!showMultiState && resSel.contains('battery') && avail.contains('battery')) 'battery',
      if (showMultiState)
        for (final id in allMetricIds) if (resSel.contains(id) && avail.contains(id)) id,
    ];
    if (ids.isEmpty) return tr('chartTitle');
    return ids.length == 1 ? metricName(ids.first) : tr('chartTitleLines');
  }

  Widget toolDivider() => Container(width: 1, height: 24, color: cBorder);

  Widget toolButton(String label, IconData icon, VoidCallback onTap, {String? badge}) {
    return HoverBox(
      onTap: () {
        buzz(0);
        onTap();
      },
      builder: (hovered) => Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: hovered ? cSoft : cPanel,
          borderRadius: BorderRadius.circular(rMd),
          border: Border.fromBorderSide(line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18, color: cMuted),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: cPrimary, fontWeight: FontWeight.w600)),
          if (badge != null) ...[
            const SizedBox(width: 6),
            Text(badge, style: const TextStyle(color: cMuted, fontWeight: FontWeight.w700)),
          ],
        ]),
      ),
    );
  }

  Future<void> popover(BuildContext ctx, Widget Function(StateSetter set) body) async {
    final box = ctx.findRenderObject() as RenderBox;
    final overlay = Overlay.of(ctx).context.findRenderObject() as RenderBox;
    final at = box.localToGlobal(Offset(0, box.size.height + 4), ancestor: overlay);
    final pos = RelativeRect.fromLTRB(at.dx, at.dy, overlay.size.width - at.dx - box.size.width, overlay.size.height - at.dy);
    await showMenu<void>(
      context: ctx,
      position: pos,
      color: cBg,
      surfaceTintColor: Colors.transparent,
      shadowColor: const Color(0x99000000),
      elevation: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rSm), side: const BorderSide(color: cBorder)),
      items: [
        PopupMenuItem<void>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: StatefulBuilder(
            builder: (c, set) => ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 260, maxWidth: 380),
              child: body(set),
            ),
          ),
        ),
      ],
    );
    seriesFocus.value = null;
  }

  Widget popHeader(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
        child: Text(text, style: const TextStyle(color: cMuted, fontSize: 12, fontWeight: FontWeight.w800)),
      );

  Widget popRow(String text, bool on, VoidCallback tap, {Color? dot, IconData? leading, bool radio = false, VoidCallback? enter, VoidCallback? leave, bool enabled = true}) {
    final icon = radio ? (on ? Icons.radio_button_checked : Icons.radio_button_unchecked) : (on ? Icons.check_box : Icons.check_box_outline_blank);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: enter == null ? null : (_) => enter(),
      onExit: leave == null ? null : (_) => leave(),
      child: InkWell(
        onTap: enabled ? tap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(children: [
            Icon(icon, size: 20, color: !enabled ? cMuted.withValues(alpha: 0.4) : (on ? cPrimary : cMuted)),
            const SizedBox(width: 10),
            if (leading != null) ...[
              Icon(leading, size: 16, color: cMuted),
              const SizedBox(width: 8),
            ],
            if (dot != null) ...[
              Container(width: 10, height: 10, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
              const SizedBox(width: 8),
            ],
            Expanded(child: Text(text, style: TextStyle(color: enabled ? cPrimary : cMuted.withValues(alpha: 0.5), fontWeight: FontWeight.w600))),
          ]),
        ),
      ),
    );
  }

  IconData platformIcon(String platform) {
    switch (platform.toLowerCase()) {
      case 'android':
        return Icons.smartphone;
      case 'macos':
      case 'windows':
      case 'linux':
        return Icons.computer;
      default:
        return Icons.devices_other;
    }
  }

  String deviceButtonLabel() {
    if (isLocalOnly) return tr('devLocal');
    if (selectedDevices.length == 1 + peerDevices.length && includesLocal) return tr('devAll');
    if (selectedDevices.length == 1) {
      final id = selectedDevices.first;
      for (final d in peerDevices) {
        if (d.id == id) return d.name;
      }
    }
    return tr('devicesCount').replaceAll('{n}', '${selectedDevices.length}');
  }

  String? deviceButtonBadge() {
    if (selectedDevices.length <= 1) return null;
    return '${selectedDevices.length}/${1 + peerDevices.length}';
  }

  Future<void> devicesPopover(BuildContext ctx) {
    return popover(ctx, (set) {
      final allIds = {'local', for (final d in peerDevices) d.id};
      final allSelected = allIds.every(selectedDevices.contains);
      void toggle(String id) {
        setState(() {
          if (selectedDevices.contains(id)) {
            if (selectedDevices.length > 1) selectedDevices.remove(id);
          } else {
            selectedDevices.add(id);
          }
          only = null;
          expandedBrowsers.clear();
          loadW0 = -1;
          dirty = true;
        });
        set(() {});
        refresh();
      }

      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        popHeader(tr('devicesBtn')),
        popRow(tr('devAll'), allSelected, () {
          setState(() {
            selectedDevices
              ..clear()
              ..addAll(allSelected ? const ['local'] : allIds);
            only = null;
            expandedBrowsers.clear();
            loadW0 = -1;
            dirty = true;
          });
          set(() {});
          refresh();
        }, leading: Icons.devices),
        const Divider(height: 8),
        popRow('${deviceName()} (${tr('devThisTag')})', selectedDevices.contains('local'), () => toggle('local'), leading: platformIcon(Platform.operatingSystem)),
        for (final d in peerDevices)
          popRow(d.name, selectedDevices.contains(d.id), () => toggle(d.id), leading: platformIcon(d.platform)),
        const SizedBox(height: 6),
      ]);
    });
  }

  Widget? remoteDeviceBadge(AppUsage r) {
    final remotes = [for (final id in r.devices) if (id != 'local') id];
    if (remotes.isEmpty) return null;
    final peerMap = {for (final d in peerDevices) d.id: d};
    final names = <String>[
      if (r.devices.contains('local')) deviceName(),
      for (final id in remotes) peerMap[id]?.name ?? id,
    ];
    final icon = r.devices.length > 1 ? Icons.devices : platformIcon(peerMap[remotes.first]?.platform ?? '');
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Tooltip(
        message: names.join(', '),
        waitDuration: const Duration(milliseconds: 200),
        child: Icon(icon, size: 15, color: cMuted),
      ),
    );
  }

  Future<void> linesPopover(BuildContext ctx) {
    return popover(ctx, (set) {
      final avail = availableResourceIds();
      final showBat = availableBattery();
      final statIds = [for (final id in statMetricIds) if (id != 'appbattery' || showBat) id];
      final ids = showMultiState
          ? allMetricIds.where(avail.contains).toList()
          : [if (avail.contains('battery')) 'battery'];
      void toggleSeries(String id) {
        setState(() {
          if (resSel.contains(id)) {
            resSel.remove(id);
          } else {
            resSel.add(id);
          }
          _cachedSeriesKey = '';
          loadChart(force: true);
        });
        set(() {});
      }

      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        popHeader(tr('linesBtn')),
        popRow(tr('lineTime'), showTime, () {
          setState(() => showTime = !showTime);
          set(() {});
        }, dot: cPrimary),
        for (final id in statIds)
          popRow(
            metricName(id),
            resSel.contains(id),
            () => toggleSeries(id),
            dot: metricColor(id),
            enter: () => seriesFocus.value = id,
            leave: () => seriesFocus.value = null,
          ),
        if (ids.isNotEmpty || (showMultiState && !Platform.isAndroid)) ...[
          const Divider(height: 8),
          for (final id in ids)
            popRow(
              metricName(id),
              resSel.contains(id),
              () => toggleSeries(id),
              dot: metricColor(id),
              enter: () => seriesFocus.value = id,
              leave: () => seriesFocus.value = null,
            ),
          if (!Platform.isAndroid && ids.isEmpty)
            Padding(padding: const EdgeInsets.fromLTRB(14, 4, 14, 8), child: Text(tr('linesHint'), style: const TextStyle(color: cMuted, fontSize: 12))),
        ],
        const SizedBox(height: 6),
      ]);
    });
  }

  Future<void> columnsSheet() async {
    buzz(1);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: cBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (c) => StatefulBuilder(
        builder: (c, set) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            popHeader(tr('optColumns')),
            for (final id in columnChoices())
              popRow(columnLabel(id), ColumnPrefs.shown(id), () {
                ColumnPrefs.set(id, !ColumnPrefs.shown(id));
                set(() {});
              }),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
  }

  Widget durationField(TextEditingController ctl, void Function(int) apply, StateSetter set, {double right = 14}) {
    final bad = ctl.text.trim().isNotEmpty && parseDuration(ctl.text) == null;
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, right, 4),
      child: TextField(
        controller: ctl,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(isDense: true, hintText: tr('durationHint'), errorText: bad ? tr('durationBad') : null),
        onChanged: (v) {
          final n = v.trim().isEmpty ? 0 : parseDuration(v);
          if (n != null) apply(n);
          set(() {});
        },
      ),
    );
  }

  Future<void> optionsPopover(BuildContext ctx, bool narrow) {
    final minCtl = TextEditingController(text: ViewPrefs.minSec == 0 ? '' : durationText(ViewPrefs.minSec));
    final maxCtl = TextEditingController(text: ViewPrefs.maxSec == 0 ? '' : durationText(ViewPrefs.maxSec));
    var maxOpen = ViewPrefs.maxSec > 0;
    return popover(ctx, (set) {
      final cols = columnChoices();
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (showMultiState) ...[
          popHeader(tr('optMode')),
          for (final m in Metric.values)
            popRow(metricLabel(m), metric == m, () {
              setState(() => metric = m);
              set(() {});
            }, radio: true),
        ],
        if (narrow && !Platform.isAndroid) ...[
          popHeader(tr('optColumns')),
          for (final id in cols)
            popRow(columnLabel(id), ColumnPrefs.shown(id), () {
              ColumnPrefs.set(id, !ColumnPrefs.shown(id));
              set(() {});
            }),
        ],
        if (!narrow && !Platform.isAndroid && (ColumnPrefs.widths.isNotEmpty || ColumnPrefs.order.isNotEmpty)) ...[
          popHeader(tr('optColumns')),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: InkWell(
              onTap: () {
                ColumnPrefs.resetWidths();
                set(() {});
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(children: [
                  const Icon(Icons.restart_alt, size: 20, color: cMuted),
                  const SizedBox(width: 10),
                  Expanded(child: Text(tr('optResetWidths'), style: const TextStyle(color: cPrimary, fontWeight: FontWeight.w600))),
                ]),
              ),
            ),
          ),
        ],
        popHeader(tr('optChart')),
        popRow(tr('avgLine'), ViewPrefs.avgLine, () {
          ViewPrefs.update(avg: !ViewPrefs.avgLine);
          set(() {});
        }),
        popRow(tr('comparePrev'), ViewPrefs.compare, () {
          ViewPrefs.update(cmp: !ViewPrefs.compare);
          set(() {});
        }),
        if (showMultiState) ...[
          popRow(tr('realFocus'), realFocusOn, () {
            ViewPrefs.update(real: !ViewPrefs.realFocus);
            set(() {});
          }, enabled: !MetricPrefs.has('notime')),
          if (MetricPrefs.has('notime')) Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 6), child: Text(tr('realFocusNeedsTime'), style: const TextStyle(color: cMuted, fontSize: 12))),
        ],
        popHeader(tr('optMinSec')),
        Row(children: [
          Expanded(child: durationField(minCtl, (n) => ViewPrefs.update(sec: n), set, right: 4)),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Tooltip(
              message: tr('optMaxSec'),
              child: InkWell(
                onTap: () => set(() => maxOpen = !maxOpen),
                child: Padding(padding: const EdgeInsets.fromLTRB(0, 0, 10, 4), child: Icon(maxOpen ? Icons.arrow_drop_down : Icons.arrow_right, size: 28, color: maxOpen ? cPrimary : cMuted)),
              ),
            ),
          ),
        ]),
        if (maxOpen) ...[
          popHeader(tr('optMaxSec')),
          durationField(maxCtl, (n) => ViewPrefs.update(max: n), set),
        ],
        const SizedBox(height: 6),
      ]);
    });
  }

  Widget chartPanelBody(bool narrow) {
    final avail = availableResourceIds();
    final activeStat = [for (final id in statMetricIds) if (resSel.contains(id)) id];
    final activeRes = showMultiState
        ? [for (final id in allMetricIds) if (resSel.contains(id) && avail.contains(id)) id]
        : [if (resSel.contains('battery') && avail.contains('battery')) 'battery'];
    final lineCount = (showTime ? 1 : 0) + activeStat.length + activeRes.length;
    final noLines = lineCount == 0;
    final devNames = {
      'local': deviceName(),
      for (final d in peerDevices) d.id: d.name,
    };
    final sKey = '${noLines ? 0 : 1}|${activeStat.join(',')}|${activeRes.join(',')}|${resPts.length}|${sysPts.length}|${statPts.length}|${only ?? ''}|${catFilter ?? ''}|$viewBucket|$loadW0|$loadW1|${ViewPrefs.minSec}|${ViewPrefs.maxSec}|$_lastDbSig|$deviceFilterKey';
    if (sKey != _cachedSeriesKey) {
      _cachedSeriesKey = sKey;
      _cachedSeries = noLines
          ? const <ResSeries>[]
          : [
              if (activeRes.isNotEmpty)
                ...buildSeries(
                  ids: resSel,
                  pts: resPts,
                  sys: sysPts,
                  only: only,
                  skip: (a) => !appAllowed(a),
                  bucketSec: viewBucket,
                  deviceNames: devNames,
                ),
              if (activeStat.isNotEmpty)
                ...buildStatSeries(
                  ids: resSel,
                  pts: statPts,
                  w0: loadW0 < 0 ? 0 : loadW0,
                  w1: loadW1 <= 0 ? dayCount * 86400 : loadW1,
                  bin: loadBin <= 0 ? 1 : loadBin,
                  bucketSec: viewBucket,
                  minSec: ViewPrefs.minSec,
                  maxSec: ViewPrefs.maxSec,
                  only: only,
                  skip: (a) => !appAllowed(a),
                ),
            ];
    }
    final seriesList = _cachedSeries;
    return Panel(
      padding: EdgeInsets.all(narrow ? 12 : 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(chartHeading(), style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          rangeSelect(),
          toolDivider(),
          AppPicker(
            value: only,
            items: [for (final app in appChoices()) PickerItem(app, titleOf(app), iconOf(app, 20))],
            current: only == null ? null : PickerItem(only!, titleOf(only!), iconOf(only!, 20)),
            onChanged: (v) => setState(() => only = v),
          ),
          if (Categories.list.value.isNotEmpty) ...[
            toolDivider(),
            SelectBox<String>(
              value: catFilter ?? '',
              items: [
                DropdownMenuItem(value: '', child: Text(tr('catAll'))),
                for (final c in Categories.list.value)
                  DropdownMenuItem(value: c.id, child: Row(mainAxisSize: MainAxisSize.min, children: [c.iconWidget(18), const SizedBox(width: 8), Text(c.name)])),
              ],
              onChanged: (v) {
                catFilter = (v == null || v.isEmpty) ? null : v;
                onViewChanged();
              },
            ),
          ],
          if (peerDevices.isNotEmpty) ...[
            toolDivider(),
            Builder(builder: (ctx) => toolButton(deviceButtonLabel(), Icons.devices, () => devicesPopover(ctx), badge: deviceButtonBadge())),
          ],
          toolDivider(),
          Builder(builder: (ctx) => toolButton(tr('linesBtn'), Icons.show_chart, () => linesPopover(ctx), badge: '$lineCount')),
          toolDivider(),
          Builder(builder: (ctx) => toolButton(tr('optionsBtn'), Icons.tune, () => optionsPopover(ctx, narrow))),
          IconButton(
            tooltip: tr('helpTitle'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.help_outline, size: 20, color: cMuted),
            onPressed: showChartHelp,
          ),
        ]),
        if (!noLines && seriesList.isNotEmpty) ...[
          const SizedBox(height: 8),
          ValueListenableBuilder<String?>(
            valueListenable: seriesFocus,
            builder: (context, focusedId, _) => Wrap(
              spacing: 14,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (showTime)
                  HoverBox(
                    onTap: () => seriesFocus.value = null,
                    builder: (_) => Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 9, height: 9, decoration: const BoxDecoration(color: cPrimary, shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      Text(tr('lineTime'), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: focusedId == null ? cPrimary : cMuted)),
                    ]),
                  ),
                for (final s in seriesList)
                  HoverBox(
                    onTap: () => seriesFocus.value = focusedId == s.id ? null : s.id,
                    builder: (_) => Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 9, height: 9, decoration: BoxDecoration(color: s.color, shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      Text(
                        s.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: focusedId == s.id ? s.color : (focusedId == null ? cPrimary : cMuted),
                        ),
                      ),
                    ]),
                  ),
              ],
            ),
          ),
        ],
        if (!noLines) const SizedBox(height: 10),
        if (!noLines)
          ActivityChart(
            key: chartKey,
            first: from,
            total: dayCount * 86400,
            contribs: contribs,
            presence: [for (final r in presenceRows) presenceMark(r)],
            siteContribs: siteContribs,
            onOpenSite: openSiteFromChart,
            assetUrl: rpcAssetUrl,
            only: only,
            metric: metric,
            title: titleOf,
            icon: iconOf,
            height: narrow ? 220 : 280,
            onView: onChartView,
            showTime: showTime,
            onPickApp: toggleOnly,
            previous: previous,
            avgLine: ViewPrefs.avgLine,
            compare: ViewPrefs.compare,
            initFrom: customChartInitFrom,
            initTo: customChartInitTo,
            series: seriesList,
          ),
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
            child: selectableDialog(EllipsisText(t, style: style)),
          ),
          row: row,
        );
    final ids = activeColumns();
    final cols = 1 + ids.length;
    return LayoutBuilder(builder: (context, area) => wideTableBody(head, ids, cols, area.maxWidth, hov, cell));
  }

  Widget wideTableBody(TextStyle head, List<String> ids, int cols, double maxWidth, Widget Function(String?, Widget, {AppUsage? row}) hov, Widget Function(String, AppUsage, {TextStyle? style}) cell) {
    final w = ColumnPrefs.widths;
    final keys = ['app', ...ids];
    final eff = <String, double>{for (final k in keys) k: math.max(colMin(k, head), w[k] ?? (k == 'app' ? 220.0 : 110.0))};
    final base = eff.values.fold<double>(0, (a, b) => a + b) + 44;
    if (w['app'] == null && base < maxWidth) eff['app'] = eff['app']! + (maxWidth - base);
    final total = eff.values.fold<double>(0, (a, b) => a + b) + 44;
    final table = Table(
      columnWidths: <int, TableColumnWidth>{
        for (var i = 0; i < keys.length; i++) i: FixedColumnWidth(eff[keys[i]]!),
        cols: const FixedColumnWidth(44),
      },
      children: [
        TableRow(children: [
          sortHead(tr('app'), 'app', head, resize: true),
          for (final id in ids) sortHead(columnLabel(id), id, head, resize: true),
          const SizedBox.shrink(),
        ]),
        for (final r in sortedRows()) ...[
          () {
            final bId = Usage.browserIdForApp(r.app);
            final sites = bId == null ? const <SiteUsage>[] : (sitesByBrowser[bId] ?? const <SiteUsage>[]);
            final expanded = sites.isNotEmpty && expandedBrowsers.contains(r.app);
            return TableRow(
              decoration: only == r.app
                  ? BoxDecoration(color: cSoft.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(8), border: Border.all(color: cPrimary))
                  : BoxDecoration(color: menuApp == r.app ? cSoft.withValues(alpha: 0.7) : (hoverApp == r.app ? cSoft.withValues(alpha: 0.35) : null), border: const Border(top: BorderSide(color: cBorder))),
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => toggleOnly(r.app),
                  onSecondaryTapUp: (d) => rowMenu(r, d.globalPosition),
                  child: DefaultSelectionStyle(
                    mouseCursor: SystemMouseCursors.click,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      onEnter: (_) => setState(() => hoverApp = r.app),
                      onExit: (_) => setState(() => hoverApp = hoverApp == r.app ? null : hoverApp),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                        child: Row(children: [
                          AppIcon(title: r.title, path: r.path, size: 22),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Flexible(child: EllipsisText(r.title, style: TextStyle(fontWeight: FontWeight.w700, color: only == r.app ? cPrimary : null))),
                              if (remoteDeviceBadge(r) case final b?) b,
                            ]),
                          ),
                          if (sites.isNotEmpty)
                            InkWell(
                              borderRadius: BorderRadius.circular(6),
                              onTap: () => setState(() => expanded ? expandedBrowsers.remove(r.app) : expandedBrowsers.add(r.app)),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                child: Icon(expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, size: 18, color: cPrimary),
                              ),
                            ),
                        ]),
                      ),
                    ),
                  ),
                ),
                for (final id in ids)
                  if (id == 'now') hov(r.app, nowCell(r), row: r) else cell(cellText(id, r), r, style: id == 'total' ? const TextStyle(fontWeight: FontWeight.w800) : null),
                hov(r.app, Align(alignment: Alignment.center, child: hideButton(r)), row: r),
              ],
            );
          }(),
          if (Usage.browserIdForApp(r.app) != null && expandedBrowsers.contains(r.app))
            for (final s in (sitesByBrowser[Usage.browserIdForApp(r.app)!] ?? const <SiteUsage>[]).take(8))
              TableRow(
                decoration: BoxDecoration(color: cSoft.withValues(alpha: 0.18)),
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onSecondaryTapUp: (d) => siteMenu(s, r, d.globalPosition),
                    child: Tooltip(
                      message: s.title.trim().isNotEmpty && s.title.trim() != s.domain ? '${s.displayTitle}\n${s.domain}' : s.openUrl,
                      waitDuration: const Duration(milliseconds: 350),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(36, 4, 6, 4),
                        child: Row(children: [
                          const Icon(Icons.public, size: 14, color: cMuted),
                          const SizedBox(width: 6),
                          Expanded(child: EllipsisText(s.displayTitle, style: const TextStyle(color: cPrimary, fontSize: 12, fontWeight: FontWeight.w600))),
                        ]),
                      ),
                    ),
                  ),
                  for (final id in ids)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onSecondaryTapUp: (d) => siteMenu(s, r, d.globalPosition),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        child: EllipsisText(
                          id == 'focused' || id == 'total' ? formatMs(s.ms) : '',
                          style: const TextStyle(color: cMuted, fontSize: 12),
                        ),
                      ),
                    ),
                  const SizedBox.shrink(),
                ],
              ),
        ],
      ],
    );
    if (total <= maxWidth + 0.5) return table;
    return Scrollbar(
      controller: tableHScroll,
      thumbVisibility: true,
      trackVisibility: true,
      interactive: true,
      child: SingleChildScrollView(
        controller: tableHScroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 12),
        child: SizedBox(width: total, child: table),
      ),
    );
  }

  double colMin(String k, TextStyle head) {
    final text = k == 'app' ? tr('app') : columnLabel(k);
    final tp = TextPainter(text: TextSpan(text: text, style: head.copyWith(fontWeight: FontWeight.w800)), textDirection: TextDirection.ltr, maxLines: 1)..layout();
    if (k == 'app') return 120.0;
    return (tp.width * 0.62 + 18).clamp(58.0, 96.0).toDouble();
  }

  Widget compactList(TextStyle head) {
    final ids = activeColumns();
    final useButtons = !Platform.isAndroid || ViewPrefs.androidControls == 'buttons';
    final sortChoices = <String>['app', ...ids];
    final defaultSort = showMultiState
        ? (metric == Metric.focused ? (realFocusOn ? 'realcol' : 'focused') : metric.name)
        : 'total';
    final effectiveSort = sortChoices.contains(sortKey)
        ? sortKey!
        : (sortChoices.contains(defaultSort) ? defaultSort : (sortChoices.contains('total') ? 'total' : sortChoices.first));

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Text('${tr('sortLabel')}: ', style: head.copyWith(fontSize: 12)),
        Flexible(
          child: SelectBox<String>(
            value: effectiveSort,
            items: [
              for (final k in sortChoices)
                DropdownMenuItem<String>(
                  value: k,
                  child: Text(k == 'app' ? tr('app') : columnLabel(k), overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) {
              if (v == null) return;
              buzz(0);
              setState(() {
                sortKey = v;
                sortAsc = v == 'app' || v == 'category';
              });
            },
          ),
        ),
        IconButton(
          tooltip: tr('sortLabel'),
          visualDensity: VisualDensity.compact,
          icon: Icon(sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 17, color: cPrimary),
          onPressed: () {
            buzz(0);
            setState(() {
              sortKey ??= effectiveSort;
              sortAsc = !sortAsc;
            });
          },
        ),
        const Spacer(),
        IconButton(
          tooltip: tr('optColumns'),
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.view_column_outlined, size: 18, color: cMuted),
          onPressed: columnsSheet,
        ),
      ]),
      for (final r in sortedRows()) ...[
        () {
          final bId = Usage.browserIdForApp(r.app);
          final sites = bId == null ? const <SiteUsage>[] : (sitesByBrowser[bId] ?? const <SiteUsage>[]);
          final expanded = sites.isNotEmpty && expandedBrowsers.contains(r.app);
          final titleWidget = EllipsisText(r.title, style: const TextStyle(fontWeight: FontWeight.w800));
          final metricIds = <String>[for (final id in ids) if (id != 'total' && id != 'now') id];
          final visibleMetrics = metricIds.length <= 4
              ? metricIds
              : [for (final id in metricIds) if (cellText(id, r) != '-') id];
          final cardBg = menuApp == r.app
              ? cSoft.withValues(alpha: 0.7)
              : (hoverApp == r.app ? cSoft.withValues(alpha: 0.35) : (only == r.app ? cSoft.withValues(alpha: 0.25) : null));

          final cardBody = Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(rMd),
              border: Border.all(color: only == r.app ? cPrimary : cBorder),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (liveMode && ids.contains('now')) ...[
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: r.now == null ? cMuted : stateColor(r.now), shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                ],
                AppIcon(title: r.title, path: r.path, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Flexible(child: useButtons ? selectableDialog(titleWidget) : titleWidget),
                    if (remoteDeviceBadge(r) case final b?) b,
                  ]),
                ),
                if (sites.isNotEmpty)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, size: 20, color: cPrimary),
                    onPressed: () => setState(() => expanded ? expandedBrowsers.remove(r.app) : expandedBrowsers.add(r.app)),
                  ),
                if (ids.contains('total')) Text(formatMs(r.total), style: const TextStyle(fontWeight: FontWeight.w900)),
                if (Platform.isAndroid && useButtons)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.more_vert, size: 18, color: cMuted),
                    onPressed: () => androidMenu(r),
                  ),
                if (useButtons) hideButton(r),
              ]),
              if (visibleMetrics.isNotEmpty) ...[
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, area) {
                    final cellW = math.max(110.0, (area.maxWidth - 8) / 2);
                    return Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final id in visibleMetrics)
                          SizedBox(
                            width: cellW,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              decoration: BoxDecoration(
                                color: cSoft.withValues(alpha: 0.28),
                                borderRadius: BorderRadius.circular(rSm),
                              ),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                EllipsisText(columnLabel(id), style: const TextStyle(color: cMuted, fontSize: 11)),
                                const SizedBox(height: 1),
                                EllipsisText(cellText(id, r), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                              ]),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
              if (expanded) ...[
                const Divider(height: 14),
                for (final s in sites.take(6))
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) => siteMenu(s, r, Platform.isAndroid ? null : d.globalPosition),
                    onSecondaryTapUp: (d) => siteMenu(s, r, d.globalPosition),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(children: [
                        const Icon(Icons.public, size: 14, color: cMuted),
                        const SizedBox(width: 6),
                        Expanded(child: EllipsisText(s.displayTitle, style: const TextStyle(color: cPrimary, fontSize: 12))),
                        Text(formatMs(s.ms), style: const TextStyle(color: cMuted, fontSize: 12, fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  ),
              ],
            ]),
          );
          final wrappedCard = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => toggleOnly(r.app),
            onSecondaryTapUp: !Platform.isAndroid ? (d) => rowMenu(r, d.globalPosition) : null,
            onLongPress: Platform.isAndroid && !useButtons ? () => androidMenu(r) : null,
            child: useButtons ? cardBody : noSelect(cardBody),
          );
          if (Platform.isAndroid) return wrappedCard;
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => hoverApp = r.app),
            onExit: (_) => setState(() => hoverApp = hoverApp == r.app ? null : hoverApp),
            child: wrappedCard,
          );
        }(),
      ],
    ]);
  }

  Widget leaderCard() {
    if (rows.isEmpty) return const SizedBox.shrink();
    AppUsage best = rows.first;
    final useFocus = rows.any((r) => r.ms[0] > 0);
    final useVisible = !useFocus && rows.any((r) => r.visible > 0);
    int score(AppUsage r) => useFocus ? (realFocusOn ? realMs(r) : r.ms[0]) : (useVisible ? r.visible : r.total);
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
            child: selectableDialog(
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: '$label: ', style: const TextStyle(color: cMuted, fontWeight: FontWeight.w700)),
                  TextSpan(text: best.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                  TextSpan(text: ' (${formatMs(score(best))})', style: const TextStyle(color: cPrimary, fontWeight: FontWeight.w800)),
                ]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (remoteDeviceBadge(best) case final b?) b,
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

  Widget globalSummaryCard(bool narrow) {
    if (globalStats.isEmpty) return const SizedBox.shrink();
    const head = TextStyle(color: cMuted, fontWeight: FontWeight.w800, fontSize: 12);
    const valStyle = TextStyle(fontWeight: FontWeight.w700, fontSize: 13);

    Widget kvRow(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Text(label, style: const TextStyle(color: cMuted, fontSize: 13))),
            Text(value, style: valStyle),
          ]),
        );

    Widget tableHeader(List<String> labels, Map<int, TableColumnWidth> widths) {
      return Table(
        columnWidths: widths,
        children: [
          TableRow(children: [
            for (var i = 0; i < labels.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Align(
                  alignment: i == 0 ? Alignment.centerLeft : Alignment.centerRight,
                  child: Text(labels[i], style: head),
                ),
              ),
          ]),
        ],
      );
    }

    Widget powerTable(Map<String, GlobalPowerRow> power, bool includeDesktopStates) {
      final kinds = [
        'sleep',
        if (includeDesktopStates || (power['hibernate']?.count ?? 0) > 0) 'hibernate',
        'lock',
        'reboot',
        'shutdown',
      ];
      String pName(String k) {
        switch (k) {
          case 'sleep':
            return tr('powerSleep');
          case 'hibernate':
            return tr('powerHibernate');
          case 'lock':
            return tr('powerLock');
          case 'reboot':
            return tr('powerReboot');
          case 'shutdown':
            return tr('powerShutdown');
          default:
            return k;
        }
      }

      const widths = <int, TableColumnWidth>{
        0: FlexColumnWidth(2),
        1: FlexColumnWidth(1),
        2: FlexColumnWidth(1.3),
      };
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('globalPowerStates'), style: head),
        const SizedBox(height: 4),
        tableHeader([tr('globalMetric'), tr('globalCount'), tr('globalDuration')], widths),
        Table(
          columnWidths: widths,
          children: [
            for (final k in kinds)
              TableRow(
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: cBorder))),
                children: [
                  Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Text(pName(k), style: const TextStyle(fontSize: 13))),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Align(alignment: Alignment.centerRight, child: Text('${power[k]?.count ?? 0}', style: valStyle)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text((power[k]?.durationMs ?? 0) > 0 ? formatMs(power[k]!.durationMs) : '-', style: valStyle),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ]);
    }

    Widget deviceSection(GlobalDeviceStats d, {bool showHeader = true}) {
      final isDesk = d.platform.toLowerCase() != 'android';
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (showHeader) ...[
          Row(children: [
            Icon(platformIcon(d.platform), size: 16, color: cMuted),
            const SizedBox(width: 8),
            Expanded(child: Text(d.name, style: const TextStyle(fontWeight: FontWeight.w800, color: cPrimary))),
          ]),
          const SizedBox(height: 8),
        ],
        if (d.ramTotalKb > 0) ...[
          Text(tr('globalRam'), style: head),
          const SizedBox(height: 2),
          kvRow(tr('globalRamTotal'), formatKb(d.ramTotalKb)),
          kvRow(tr('globalRamUsed'), formatKb(d.ramUsedKb)),
          kvRow(tr('globalRamFree'), formatKb(d.ramFreeKb)),
          const Divider(height: 16),
        ],
        if (d.disks.isNotEmpty) ...[
          Text(tr('globalDisks'), style: head),
          const SizedBox(height: 4),
          tableHeader(
            [tr('globalDiskMount'), tr('globalDiskTotal'), tr('globalDiskUsed'), tr('globalDiskFree')],
            const <int, TableColumnWidth>{
              0: FlexColumnWidth(1.4),
              1: FlexColumnWidth(1),
              2: FlexColumnWidth(1),
              3: FlexColumnWidth(1),
            },
          ),
          Table(
            columnWidths: const <int, TableColumnWidth>{
              0: FlexColumnWidth(1.4),
              1: FlexColumnWidth(1),
              2: FlexColumnWidth(1),
              3: FlexColumnWidth(1),
            },
            children: [
              for (final disk in d.disks)
                TableRow(
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: cBorder))),
                  children: [
                    Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: EllipsisText(disk.mount, style: const TextStyle(fontSize: 13))),
                    Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Align(alignment: Alignment.centerRight, child: Text(formatKb(disk.totalKb), style: valStyle))),
                    Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Align(alignment: Alignment.centerRight, child: Text(formatKb(disk.usedKb), style: valStyle))),
                    Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Align(alignment: Alignment.centerRight, child: Text(formatKb(disk.freeKb), style: valStyle))),
                  ],
                ),
            ],
          ),
          const Divider(height: 16),
        ],
        if (d.batteryPct >= 0 || d.batteryDrainTenths > 0) ...[
          Text(tr('globalBattery'), style: head),
          const SizedBox(height: 2),
          if (d.batteryPct >= 0)
            kvRow(tr('mBattery'), '${d.batteryPct}% (${tr(d.batteryCharging != 0 ? 'batteryCharging' : 'batteryDischarging')})'),
          if (d.batteryDrainTenths > 0)
            kvRow(tr('globalBatteryDrain'), '${(d.batteryDrainTenths / 10).toStringAsFixed(1)}%'),
          const Divider(height: 16),
        ],
        Text(tr('globalActivity'), style: head),
        const SizedBox(height: 2),
        if (d.focusedMs > 0 || isDesk) kvRow(tr('focused'), formatMs(d.focusedMs)),
        if (d.visibleMs > 0 || isDesk) kvRow(tr('visibleAll'), formatMs(d.visibleMs)),
        kvRow(tr('total'), formatMs(d.totalMs)),
        if (d.afkMs > 0) kvRow(tr('globalAfk'), formatMs(d.afkMs)),
        kvRow(tr('opens'), '${d.opens}'),
        if (d.notifs > 0 || !isDesk) kvRow(tr('notifs'), '${d.notifs}'),
        kvRow(tr('unlocksLabel'), '${d.unlocks}'),
        const Divider(height: 16),
        powerTable(d.power, isDesk),
      ]);
    }

    final multi = globalStats.length > 1;
    final tot = GlobalDeviceStats('totals', tr('globalTotals'), showMultiState ? 'desktop' : 'android');
    if (multi) {
      for (final d in globalStats) {
        tot.ramTotalKb += d.ramTotalKb;
        tot.ramFreeKb += d.ramFreeKb;
        tot.focusedMs += d.focusedMs;
        tot.visibleMs += d.visibleMs;
        tot.totalMs += d.totalMs;
        tot.afkMs += d.afkMs;
        tot.opens += d.opens;
        tot.notifs += d.notifs;
        tot.unlocks += d.unlocks;
        tot.batteryDrainTenths += d.batteryDrainTenths;
        for (final e in d.power.entries) {
          final p = tot.power.putIfAbsent(e.key, GlobalPowerRow.new);
          p.count += e.value.count;
          p.durationMs += e.value.durationMs;
        }
      }
    }

    return Panel(
      padding: EdgeInsets.all(narrow ? 12 : 16),
      child: selectableDialog(
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('globalSummary'), style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          for (var i = 0; i < globalStats.length; i++) ...[
            if (i > 0) const Divider(height: 24),
            deviceSection(globalStats[i], showHeader: multi),
          ],
          if (multi) ...[
            const Divider(height: 24),
            deviceSection(tot, showHeader: true),
          ],
        ]),
      ),
    );
  }

  Widget activity(bool narrow) {
    const head = TextStyle(color: cMuted, fontWeight: FontWeight.w800);
    final hasGlobal = globalStats.isNotEmpty;
    final tabIdx = hasGlobal ? dataTab : 0;

    Widget tabBtn(int idx, IconData icon, String label) {
      final active = tabIdx == idx;
      return InkWell(
        borderRadius: BorderRadius.circular(rSm),
        onTap: () {
          if (tabIdx == idx) return;
          buzz(0);
          setState(() => dataTab = idx);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: active ? cPrimary.withValues(alpha: 0.16) : cSoft.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(rSm),
            border: Border.all(color: active ? cPrimary : cBorder),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: active ? cPrimary : cMuted),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: active ? cPrimary : cMuted)),
          ]),
        ),
      );
    }

    final bodyCard = tabIdx == 1
        ? globalSummaryCard(narrow)
        : (rows.isEmpty
            ? Panel(child: selectableDialog(Text(tr('noData'))))
            : Panel(
                padding: EdgeInsets.all(narrow ? 12 : 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  narrow ? compactList(head) : wideTable(head),
                ]),
              ));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      leaderCard(),
      chartPanel(narrow),
      const SizedBox(height: 12),
      if (hasGlobal) ...[
        Row(children: [
          tabBtn(0, Icons.apps_outlined, tr('navAppsTab')),
          const SizedBox(width: 8),
          tabBtn(1, Icons.assessment_outlined, tr('globalSummary')),
        ]),
        const SizedBox(height: 8),
      ],
      if (hasGlobal && narrow)
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: (d) {
            final vx = d.primaryVelocity ?? 0;
            if (vx < -280 && dataTab == 0) {
              buzz(0);
              setState(() => dataTab = 1);
            } else if (vx > 280 && dataTab == 1) {
              buzz(0);
              setState(() => dataTab = 0);
            }
          },
          child: bodyCard,
        )
      else
        bodyCard,
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

  bool _inBox(GlobalKey k, Offset globalPos) {
    final box = k.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return false;
    return (box.localToGlobal(Offset.zero) & box.size).contains(globalPos);
  }

  void _stopAutoScroll() {
    autoScrollTimer?.cancel();
    autoScrollTimer = null;
    if (autoScrollOrigin != null || autoScrollCursor != null) {
      setState(() {
        autoScrollOrigin = null;
        autoScrollCursor = null;
        autoScrollMoved = false;
      });
    }
  }

  void _startAutoScroll(Offset origin) {
    autoScrollTimer?.cancel();
    setState(() {
      autoScrollOrigin = origin;
      autoScrollCursor = origin;
      autoScrollMoved = false;
    });
    shellFocus.requestFocus();
    autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!mounted || autoScrollOrigin == null || autoScrollCursor == null) return;
      final d = autoScrollCursor! - autoScrollOrigin!;
      const dz = 14.0;
      double step(double delta) => delta.abs() <= dz ? 0 : (delta - delta.sign * dz) * 0.22;
      final dx = step(d.dx);
      final dy = step(d.dy);
      if (dy != 0 && vScroll.hasClients) {
        vScroll.jumpTo((vScroll.offset + dy).clamp(0.0, vScroll.position.maxScrollExtent));
      }
      if (dx != 0 && tableHScroll.hasClients) {
        tableHScroll.jumpTo((tableHScroll.offset + dx).clamp(0.0, tableHScroll.position.maxScrollExtent));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final narrow = c.maxWidth < narrowWidth;
      final title = tab == 0 ? tr('navActivity') : tr('navSettings');
      final pad = narrow ? 12.0 : 18.0;
      return Scaffold(
        body: SafeArea(
          child: ValueListenableBuilder<bool>(
            valueListenable: chartPinch,
            builder: (context, pinching, _) => DefaultSelectionStyle(
              mouseCursor: SystemMouseCursors.basic,
              child: column(narrow, title, pad, pinching),
            ),
          ),
        ),
      );
    });
  }

  Widget column(bool narrow, String title, double pad, bool pinching) {
    final list = ListView(
      controller: vScroll,
      physics: pinching ? const NeverScrollableScrollPhysics() : null,
      padding: EdgeInsets.fromLTRB(pad, pad, pad, 28),
      children: [
        Wrap(spacing: 16, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          selectableDialog(Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900))),
          if (tab == 0) statusChip(),
        ]),
        const SizedBox(height: 14),
        tab == 0
            ? activity(narrow)
            : SettingsPage(
                onWithdraw: widget.onWithdraw,
                onExport: exportCsv,
                onCheck: () async {
                  final info = await checkUpdate();
                  if (mounted) setState(() => update = info);
                  return info;
                },
              ),
      ],
    );

    final scrollable = Platform.isAndroid
        ? list
        : KeyboardListener(
            focusNode: shellFocus,
            onKeyEvent: (ev) {
              if (ev is KeyDownEvent && ev.logicalKey == LogicalKeyboardKey.escape && autoScrollOrigin != null) {
                _stopAutoScroll();
              }
            },
            child: Listener(
              onPointerDown: (e) {
                if (autoScrollOrigin != null) {
                  _stopAutoScroll();
                  return;
                }
                if (e.kind == PointerDeviceKind.mouse && e.buttons == kMiddleMouseButton && !_inBox(chartKey, e.position)) {
                  _startAutoScroll(e.localPosition);
                }
              },
              onPointerMove: (e) {
                if (autoScrollOrigin == null) return;
                autoScrollCursor = e.localPosition;
                if ((e.localPosition - autoScrollOrigin!).distance > 14) autoScrollMoved = true;
              },
              onPointerUp: (_) {
                if (autoScrollOrigin != null && autoScrollMoved) _stopAutoScroll();
              },
              onPointerCancel: (_) {
                if (autoScrollOrigin != null) _stopAutoScroll();
              },
              child: Stack(children: [
                list,
                if (autoScrollOrigin != null)
                  Positioned(
                    left: autoScrollOrigin!.dx - 16,
                    top: autoScrollOrigin!.dy - 16,
                    child: IgnorePointer(
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: cBg.withValues(alpha: 0.92),
                          shape: BoxShape.circle,
                          border: Border.all(color: cPrimary, width: 1.5),
                          boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 8)],
                        ),
                        child: const Icon(Icons.open_with, size: 17, color: cPrimary),
                      ),
                    ),
                  ),
              ]),
            ),
          );

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
                  child: scrollable,
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

class _SettingsPageState extends State<SettingsPage> with WidgetsBindingObserver {
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
  late int afkSeconds = readAfkSeconds();
  late final TextEditingController afkCtl = TextEditingController(text: afkSeconds == 0 ? '0' : durationText(afkSeconds));
  String? afkError;
  bool rpcRestarting = false;
  Timer? rpcTimer;
  String? extStatusText;
  bool extConnected = false;
  bool p2pEnabled = P2pSync.instance.enabled;
  List<LocalAddress> localIps = [];
  String? p2pStatusText;
  bool p2pStatusOk = true;
  bool p2pSyncing = false;
  String? p2pSyncingPeerId;
  late bool crashLogs = !prefs.flag('nocrashlogs');
  bool browserAccess = false;

  void copyText(String value) {
    Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text('${tr('copied')}: $value'), duration: const Duration(seconds: 2)));
  }

  Widget wrapSelectable(Widget child) => selectableRegion(child);

  List<AppEntry> appEntries() {
    final m = metricsUsage.names();
    final real = Platform.isAndroid ? m.keys.toSet() : metricsUsage.windowed();
    return [for (final e in m.entries) if (real.contains(e.key) && !Categories.isNoise(e.key, e.value.name)) AppEntry(e.key, e.value.name.isNotEmpty ? e.value.name : prettyApp(e.key), e.value.path, 0, true)];
  }

  Widget limitsSection() {
    return ValueListenableBuilder<List<DayLimit>>(
      valueListenable: LimitPrefs.list,
      builder: (context, items, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(tr('limitsTitle'), style: const TextStyle(fontWeight: FontWeight.w700))),
          OutlinedButton.icon(icon: const Icon(Icons.add, size: 18), label: Text(tr('limitNew')), onPressed: () => limitDialog(context, entries: appEntries())),
        ]),
        Align(alignment: Alignment.centerLeft, child: Text(tr('limitsHint'), style: const TextStyle(color: cMuted, fontSize: 12))),
        for (final l in items)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Icon(l.kind == 'cat' ? Icons.label_outline : Icons.apps, size: 20, color: cMuted),
              const SizedBox(width: 10),
              Expanded(child: Text('${l.kind == 'cat' ? (Categories.byId(l.id)?.name ?? l.name) : l.name} - ${durationText(l.seconds)}', overflow: TextOverflow.ellipsis)),
              IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.edit_outlined, size: 20), onPressed: () => limitDialog(context, app: l.kind == 'app' ? l.id : null, title: l.name, entries: appEntries())),
              IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.delete_outline, size: 20, color: cDanger), onPressed: () => LimitPrefs.remove(l)),
            ]),
          ),
      ]),
    );
  }

  Future<void> confirmDelete(Category c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: cPanel,
        title: Text(tr('catDelete')),
        content: wrapSelectable(Text(tr('catDeleteConfirm').replaceAll('{name}', c.name))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('cancel'))),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('catDelete'), style: const TextStyle(color: cDanger))),
        ],
      ),
    );
    if (ok == true) Categories.remove(c.id);
  }

  Widget categoriesSection() {
    return ValueListenableBuilder<List<Category>>(
      valueListenable: Categories.list,
      builder: (context, cats, _) {
        List<AppEntry> entries() {
          final m = metricsUsage.names();
          final today = DateTime.now();
          final first = today.subtract(const Duration(days: 30));
          String k(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
          final seen = {for (final r in metricsUsage.range(k(first), k(today))) r.app: r.visible};
          final real = Platform.isAndroid ? m.keys.toSet() : metricsUsage.windowed();
          return [for (final e in m.entries) AppEntry(e.key, e.value.name.isNotEmpty ? e.value.name : prettyApp(e.key), e.value.path, seen[e.key] ?? 0, real.contains(e.key))];
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(tr('catTitle'), style: const TextStyle(fontWeight: FontWeight.w700))),
            OutlinedButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: Text(tr('catNew')),
              onPressed: () => categoryEditor(context, bridge: collector?.bridge),
            ),
          ]),
          Align(alignment: Alignment.centerLeft, child: Text(tr('catHint'), style: const TextStyle(color: cMuted, fontSize: 12))),
          for (final c in cats)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                c.iconWidget(26),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text('${tr('catApps')}: ${c.apps.length}', style: const TextStyle(color: cMuted, fontSize: 12)),
                  ]),
                ),
                IconButton(tooltip: tr('catApps'), visualDensity: VisualDensity.compact, icon: const Icon(Icons.apps, size: 20), onPressed: () => categoryApps(context, c, entries())),
                IconButton(tooltip: tr('catEdit'), visualDensity: VisualDensity.compact, icon: const Icon(Icons.edit_outlined, size: 20), onPressed: () => categoryEditor(context, edit: c, bridge: collector?.bridge)),
                IconButton(tooltip: tr('catDelete'), visualDensity: VisualDensity.compact, icon: const Icon(Icons.delete_outline, size: 20, color: cDanger), onPressed: () => confirmDelete(c)),
              ]),
            ),
        ]);
      },
    );
  }

  String readRpcStatus() {
    try {
      return File('${dataDir()}${Platform.pathSeparator}discordrpc.status').readAsStringSync().trim();
    } catch (_) {
      return '';
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    rpcTimer?.cancel();
    metricsUsage.close();
    afkCtl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid || state != AppLifecycleState.resumed) return;
    collector?.bridge.hasBrowserAccess().then((v) {
      if (mounted && v != browserAccess) setState(() => browserAccess = v);
    });
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
        backgroundColor: cPanel,
        title: Text(tr('discordRpc')),
        content: wrapSelectable(Text(tr('rpcRestartHelp'))),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('ok')))],
      ),
    );
  }

  int rowsTimeCost(Forecast f) => f.rowsPerDay * forecastDays * timeRowBytes;

  void apiHelp() {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: cPanel,
        title: Text(tr('localApi')),
        content: wrapSelectable(Text(tr('localApiHint'))),
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
        content: wrapSelectable(
          TextField(
            controller: controller,
            autofocus: true,
            maxLength: 64,
            decoration: InputDecoration(hintText: tr('deviceNameHint')),
            onSubmitted: (v) => Navigator.pop(c, v),
          ),
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
    P2pSync.instance.version.value++;
    if (P2pSync.instance.peers.value.isNotEmpty) {
      unawaited(P2pSync.instance.syncAll());
    }
  }

  Future<void> toggleApi(bool v) async {
    if (v) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: cPanel,
          title: Text(tr('localApi')),
          content: wrapSelectable(Text(tr('localApiWarn'))),
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
    WidgetsBinding.instance.addObserver(this);
    rpcStatus = readRpcStatus();
    rpcTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final v = readRpcStatus();
      if (mounted && v != rpcStatus) setState(() => rpcStatus = v);
    });
    autostartEnabled().then((v) {
      if (mounted && v != auto) setState(() => auto = v);
    });
    P2pSync.instance.localIpDetails().then((ips) {
      if (mounted) setState(() => localIps = ips);
    });
    if (Platform.isAndroid) {
      collector?.bridge.hasBrowserAccess().then((v) {
        if (mounted) setState(() => browserAccess = v);
      });
    }
  }

  String _extFolderPath() {
    final extDir = '${installDir()}${Platform.pathSeparator}extensions${Platform.pathSeparator}wolium-browser';
    return Directory(extDir).existsSync() ? extDir : installDir();
  }

  Future<bool> _openBrowserExtensionsTab(({String id, String name, String? exe, String url}) target) async {
    Clipboard.setData(ClipboardData(text: target.url));
    final setupUri = Uri.http('127.0.0.1:9095', '/ext-setup', {
      'url': target.url,
      'browser': target.name,
      'dir': _extFolderPath(),
      'lang': language.value,
    }).toString();
    try {
      if (Platform.isWindows && target.exe != null && File(target.exe!).existsSync()) {
        await Process.start(target.exe!, [setupUri], mode: ProcessStartMode.detached);
        return true;
      }
      if (Platform.isMacOS && target.name.isNotEmpty) {
        final res = await Process.run('open', ['-a', target.name, setupUri]);
        if (res.exitCode == 0) return true;
      }
      if (Platform.isLinux && target.exe != null && File(target.exe!).existsSync()) {
        await Process.start(target.exe!, [setupUri], mode: ProcessStartMode.detached);
        return true;
      }
      if (await launchUrl(Uri.parse(setupUri), mode: LaunchMode.externalApplication)) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  Future<void> openExtensionGuide() async {
    final extDir = _extFolderPath();
    final detected = detectBrowserTargets(metricsUsage);
    final targets = detected.isNotEmpty
        ? detected
        : <({String id, String name, String? exe, String url})>[
            (id: 'chrome', name: 'Chrome', exe: null, url: 'chrome://extensions'),
          ];
    var selectedIdx = 0;
    Clipboard.setData(ClipboardData(text: extDir));
    String? notice = tr('extPathAutoCopied');
    var noticeOk = true;
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setDlg) {
          final target = targets[selectedIdx];
          final openLabel = target.name.isNotEmpty ? tr('extOpenTabNamed').replaceAll('{browser}', target.name) : tr('extOpenTab');
          return AlertDialog(
            backgroundColor: cPanel,
            title: Text(tr('extGuideTitle')),
            content: SizedBox(
              width: 540,
              child: wrapSelectable(
                SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('extGuideIntro'), style: const TextStyle(color: cMuted, fontSize: 13)),
                    if (targets.length > 1) ...[
                      const SizedBox(height: 10),
                      Text(tr('extMultiBrowserHint'), style: const TextStyle(color: cMuted, fontSize: 12, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        for (var i = 0; i < targets.length; i++)
                          ChoiceChip(
                            label: Text(targets[i].name),
                            selected: i == selectedIdx,
                            onSelected: (_) => setDlg(() => selectedIdx = i),
                          ),
                      ]),
                    ],
                    const SizedBox(height: 12),
                    Text(tr('extGuideStep1'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      FilledButton.icon(
                        icon: const Icon(Icons.open_in_new, size: 17),
                        label: Text(openLabel, overflow: TextOverflow.ellipsis),
                        onPressed: () async {
                          final ok = await _openBrowserExtensionsTab(target);
                          if (c.mounted) {
                            setDlg(() {
                              noticeOk = ok;
                              notice = ok ? tr('extSetupOpened').replaceAll('{url}', target.url) : tr('extOpenFallback');
                            });
                          }
                        },
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.copy, size: 16),
                        label: Text(tr('extCopyUrl')),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: target.url));
                          setDlg(() {
                            noticeOk = true;
                            notice = '${tr('copied')}: ${target.url}';
                          });
                        },
                      ),
                    ]),
                    const SizedBox(height: 12),
                    Text(tr('extGuideStep2'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                    const SizedBox(height: 10),
                    Text(tr('extGuideStep3'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(color: cSoft, borderRadius: BorderRadius.circular(rSm), border: Border.fromBorderSide(line)),
                      child: Row(children: [
                        Expanded(child: Text(extDir, style: const TextStyle(fontSize: 12))),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: tr('extCopyPath'),
                          icon: const Icon(Icons.copy, size: 17),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: extDir));
                            setDlg(() {
                              noticeOk = true;
                              notice = '${tr('copied')}: $extDir';
                            });
                          },
                        ),
                      ]),
                    ),
                    if (notice != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(notice!, style: TextStyle(color: noticeOk ? cOk : cWarn, fontSize: 12, fontWeight: FontWeight.w700)),
                      ),
                    const SizedBox(height: 8),
                    Text(tr('extGuideFirefox'), style: const TextStyle(color: cMuted, fontSize: 12)),
                    const SizedBox(height: 10),
                    Text(tr('extGuideStep4'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  ]),
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('ok'))),
            ],
          );
        },
      ),
    );
  }

  Future<void> wizardStep1() async {
    if (!localApi) return;
    Clipboard.setData(ClipboardData(text: _extFolderPath()));
    setState(() => extStatusText = tr('extStep1Done'));
    if (mounted) await openExtensionGuide();
  }

  Future<void> wizardStep2() async {
    if (!localApi) return;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:9095/v1/browser/top?days=1&limit=3'));
      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();
      final map = jsonDecode(body) as Map<String, dynamic>;
      final domains = map['domains'] as List<dynamic>? ?? const [];
      final count = domains.length;
      final missingTitle = count > 0 && domains.every((d) => d is Map && ((d['title'] as String? ?? '').trim().isEmpty));
      if (mounted) {
        setState(() {
          extConnected = res.statusCode == 200;
          extStatusText = res.statusCode == 200
              ? (missingTitle ? '${tr('extConnected').replaceAll('{n}', '$count')}\n${tr('extReloadHint')}' : tr('extConnected').replaceAll('{n}', '$count'))
              : tr('extOffline');
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          extConnected = false;
          extStatusText = tr('extOffline');
        });
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> openConnectDialog() async {
    final ipCtl = TextEditingController();
    final pinCtl = TextEditingController();
    String? err;
    var busy = false;
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setDlg) => AlertDialog(
          backgroundColor: cPanel,
          title: Text(tr('p2pConnect')),
          content: wrapSelectable(
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: ipCtl,
                decoration: InputDecoration(labelText: tr('p2pIpHint'), hintText: '192.168.1.42:9096'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: pinCtl,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(labelText: tr('p2pPinHint'), hintText: '123456'),
              ),
              if (err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Text(err!, style: const TextStyle(color: cDanger, fontSize: 12))),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: tr('copy'),
                      icon: const Icon(Icons.copy, size: 16, color: cMuted),
                      onPressed: () => copyText(err!),
                    ),
                  ]),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(c), child: Text(tr('cancel'))),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setDlg(() {
                        busy = true;
                        err = null;
                      });
                      final e = await P2pSync.instance.pairWithPeer(ipCtl.text, pinCtl.text);
                      if (!c.mounted) return;
                      if (e == null) {
                        Navigator.pop(c);
                        if (mounted) {
                          setState(() {
                            p2pStatusOk = true;
                            p2pStatusText = tr('p2pPaired');
                          });
                        }
                      } else {
                        setDlg(() {
                          busy = false;
                          err = e;
                        });
                      }
                    },
              child: Text(tr('p2pPairBtn')),
            ),
          ],
        ),
      ),
    );
    ipCtl.dispose();
    pinCtl.dispose();
  }

  Widget browserExtSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr('extTitle'), style: const TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 2),
      Text(tr('extHint'), style: const TextStyle(color: cMuted, fontSize: 12)),
      const SizedBox(height: 4),
      Text(tr('updateExtNotice'), style: const TextStyle(color: cMuted, fontSize: 12)),
      if (!localApi) ...[
        const SizedBox(height: 6),
        Text(tr('extRequiresApi'), style: const TextStyle(color: cWarn, fontSize: 12, fontWeight: FontWeight.w700)),
      ],
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.extension_outlined, size: 18),
          label: Text(tr('extStep1')),
          onPressed: localApi ? wizardStep1 : null,
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.check_circle_outline, size: 18),
          label: Text(tr('extStep2')),
          onPressed: localApi ? wizardStep2 : null,
        ),
      ]),
      if (extStatusText != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(extStatusText!, style: TextStyle(color: extConnected ? cOk : cMuted, fontWeight: FontWeight.w700, fontSize: 12)),
        ),
    ]);
  }

  Widget p2pSyncSection() {
    return ValueListenableBuilder<List<PeerDevice>>(
      valueListenable: P2pSync.instance.peers,
      builder: (context, peers, _) => ValueListenableBuilder<String?>(
        valueListenable: P2pSync.instance.activePin,
        builder: (context, pin, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(tr('p2pTitle'), style: const TextStyle(fontWeight: FontWeight.w700))),
            Switch(
              value: p2pEnabled,
              onChanged: (v) async {
                await P2pSync.instance.setEnabled(v);
                if (mounted) setState(() => p2pEnabled = v);
              },
            ),
          ]),
          Text(tr('p2pHint'), style: const TextStyle(color: cMuted, fontSize: 12)),
          if (localIps.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(tr('p2pYourIps'), style: const TextStyle(color: cMuted, fontSize: 11)),
            const SizedBox(height: 4),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final ip in localIps)
                ActionChip(
                  avatar: Icon(Icons.copy, size: 14, color: ip.virtual ? cMuted : cPrimary),
                  label: Text(
                    ip.virtual ? '${ip.address}:$kP2pPort · ${tr('p2pVirtual')}' : '${ip.address}:$kP2pPort',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: ip.virtual ? cMuted : cPrimary),
                  ),
                  onPressed: () => copyText('${ip.address}:$kP2pPort'),
                ),
            ]),
          ],
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.pin_outlined, size: 18),
              label: Text(pin == null ? tr('p2pShowPin') : tr('p2pHidePin')),
              onPressed: () async {
                if (!p2pEnabled) {
                  await P2pSync.instance.setEnabled(true);
                  if (mounted) setState(() => p2pEnabled = true);
                }
                if (pin == null) {
                  P2pSync.instance.startPinSession();
                } else {
                  P2pSync.instance.cancelPinSession();
                }
              },
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.devices, size: 18),
              label: Text(tr('p2pConnect')),
              onPressed: openConnectDialog,
            ),
            if (peers.isNotEmpty)
              OutlinedButton.icon(
                icon: p2pSyncing && p2pSyncingPeerId == null
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync, size: 18),
                label: Text(p2pSyncing ? tr('p2pSyncing') : tr('p2pSyncNow')),
                onPressed: p2pSyncing
                    ? null
                    : () async {
                        setState(() {
                          p2pSyncing = true;
                          p2pSyncingPeerId = null;
                          p2pStatusOk = true;
                          p2pStatusText = tr('p2pSyncing');
                        });
                        final n = await P2pSync.instance.syncAll();
                        if (mounted) {
                          setState(() {
                            p2pSyncing = false;
                            p2pSyncingPeerId = null;
                            p2pStatusOk = n > 0;
                            p2pStatusText = tr('p2pSynced').replaceAll('{n}', '$n');
                          });
                        }
                      },
              ),
          ]),
          if (pin != null)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: cPrimary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(rSm), border: Border.all(color: cPrimary)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('${tr('p2pPinLabel')}: ', style: const TextStyle(color: cMuted, fontWeight: FontWeight.w700)),
                Text(pin, style: const TextStyle(color: cPrimary, fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 4)),
                const SizedBox(width: 6),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: tr('copy'),
                  icon: const Icon(Icons.copy, size: 18, color: cPrimary),
                  onPressed: () => copyText(pin),
                ),
              ]),
            ),
          if (p2pStatusText != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(p2pStatusText!, style: TextStyle(color: p2pStatusOk ? (p2pSyncing ? cPrimary : cOk) : cDanger, fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          for (final d in peers)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                Icon(d.platform.toLowerCase() == 'android' ? Icons.smartphone : Icons.computer, size: 18, color: cMuted),
                const SizedBox(width: 8),
                Expanded(child: Text('${d.name} (${d.host}:${d.port})', style: const TextStyle(fontWeight: FontWeight.w600))),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: tr('p2pSyncNow'),
                  icon: p2pSyncing && p2pSyncingPeerId == d.id
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.sync, size: 18),
                  onPressed: p2pSyncing
                      ? null
                      : () async {
                          setState(() {
                            p2pSyncing = true;
                            p2pSyncingPeerId = d.id;
                            p2pStatusOk = true;
                            p2pStatusText = tr('p2pSyncing');
                          });
                          final ok = await P2pSync.instance.syncPeer(d);
                          if (mounted) {
                            setState(() {
                              p2pSyncing = false;
                              p2pSyncingPeerId = null;
                              p2pStatusOk = ok;
                              p2pStatusText = ok ? tr('p2pSynced').replaceAll('{n}', '1') : tr('p2pSyncErr');
                            });
                          }
                        },
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: tr('p2pRemove'),
                  icon: const Icon(Icons.delete_outline, size: 18, color: cDanger),
                  onPressed: () => P2pSync.instance.unpair(d.id),
                ),
              ]),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final panel = Panel(
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
        if (!Platform.isAndroid) ...[
          Row(children: [
            Expanded(child: Text(tr('afkTitle'), style: const TextStyle(fontWeight: FontWeight.w700))),
            SizedBox(
              width: 150,
              child: TextField(
                controller: afkCtl,
                decoration: InputDecoration(isDense: true, hintText: tr('durationHint'), errorText: afkError),
                onChanged: (v) {
                  final n = v.trim() == '0' ? 0 : parseDuration(v);
                  setState(() => afkError = n == null ? tr('durationBad') : (n != 0 && (n < 30 || n > 3600) ? tr('afkRange') : null));
                  if (n == null || afkError != null) return;
                  afkSeconds = n;
                  writeAfkSeconds(afkSeconds);
                },
              ),
            ),
          ]),
          Align(alignment: Alignment.centerLeft, child: Text(tr('afkHint'), style: const TextStyle(color: cMuted, fontSize: 12))),
          const Divider(height: 28),
        ],
        categoriesSection(),
        const Divider(height: 28),
        limitsSection(),
        const Divider(height: 28),
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
        if (Platform.isAndroid) ...[
          const Divider(height: 28),
          Row(children: [
            Expanded(child: Text(tr('browserTrackingTitle'), style: const TextStyle(fontWeight: FontWeight.w700))),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: browserAccess ? cOk : cWarn, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(
                tr(browserAccess ? 'browserTrackingActive' : 'browserTrackingInactive'),
                style: TextStyle(color: browserAccess ? cOk : cWarn, fontWeight: FontWeight.w700, fontSize: 12),
              ),
            ]),
          ]),
          const SizedBox(height: 2),
          Text(tr('browserTrackingDesc'), style: const TextStyle(color: cMuted, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.accessibility_new, size: 18),
              label: Text(tr('browserTrackingOpenSettings')),
              onPressed: () async {
                await collector?.bridge.openAccessibility();
                final ok = await collector?.bridge.hasBrowserAccess() ?? false;
                if (mounted) setState(() => browserAccess = ok);
              },
            ),
            if (!browserAccess)
              OutlinedButton.icon(
                icon: const Icon(Icons.info_outline, size: 18),
                label: Text(tr('browserTrackingOpenAppInfo')),
                onPressed: () async {
                  await collector?.bridge.openOwnAppInfo();
                },
              ),
          ]),
          if (!browserAccess) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cWarn.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(rSm),
                border: Border.all(color: cWarn.withValues(alpha: 0.3)),
              ),
              child: Text(tr('browserTrackingRestrictedHint'), style: const TextStyle(color: cMuted, fontSize: 12)),
            ),
          ],
        ],
        if (!Platform.isAndroid) ...[
          const Divider(height: 28),
          browserExtSection(),
        ],
        const Divider(height: 28),
        p2pSyncSection(),
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
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('androidControlsTitle'), style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(tr('androidControlsHint'), style: const TextStyle(color: cMuted, fontSize: 12)),
              ]),
            ),
            SelectBox<String>(
              value: ViewPrefs.androidControls,
              items: [
                DropdownMenuItem(value: 'gestures', child: Text(tr('androidControlsGestures'))),
                DropdownMenuItem(value: 'buttons', child: Text(tr('androidControlsButtons'))),
              ],
              onChanged: (v) {
                ViewPrefs.update(controls: v ?? 'gestures');
                buzz(1);
                setState(() {});
              },
            ),
          ]),
          const Divider(height: 28),
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
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('crashLogsTitle'), style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(tr('crashLogsHint'), style: const TextStyle(color: cMuted, fontSize: 12)),
              ]),
            ),
            Switch(
              value: crashLogs,
              onChanged: (v) async {
                prefs.setFlag('nocrashlogs', !v);
                await collector?.bridge.setCrashLogs(v);
                if (mounted) setState(() => crashLogs = v);
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
            Expanded(child: Text(dataDir())),
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
              Text(exportedPath!, style: const TextStyle(color: cMuted, fontSize: 12)),
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
    return wrapSelectable(panel);
  }
}

String _extUrlForBrowser(String idOrName) {
  final l = idOrName.toLowerCase();
  if (l.contains('opera')) return 'opera://extensions';
  if (l.contains('msedge') || l.contains('edge')) return 'edge://extensions';
  if (l.contains('firefox') || l.contains('librewolf') || l.contains('floorp') || l.contains('waterfox') || l.contains('zen') || l.contains('mullvad') || l.contains('palemoon')) {
    return 'about:debugging#/runtime/this-firefox';
  }
  if (l.contains('vivaldi')) return 'vivaldi://extensions';
  if (l.contains('brave')) return 'brave://extensions';
  return 'chrome://extensions';
}

List<({String id, String name, String? exe, String url})> detectBrowserTargets(Usage metricsUsage) {
  final out = <({String id, String name, String? exe, String url})>[];
  final seenExes = <String>{};
  final seenNames = <String>{};

  void addTarget(String rawId, String name, String? exe) {
    final cleanName = name.trim();
    if (cleanName.isEmpty) return;
    final normExe = exe?.trim() ?? '';
    if (normExe.isNotEmpty) {
      final key = Platform.isWindows ? normExe.toLowerCase() : normExe;
      if (seenExes.contains(key)) return;
      seenExes.add(key);
    } else {
      final nKey = cleanName.toLowerCase();
      if (seenNames.contains(nKey)) return;
    }
    seenNames.add(cleanName.toLowerCase());
    final bId = Usage.browserIdForApp(rawId) ?? Usage.browserIdForApp(cleanName) ?? rawId.toLowerCase();
    out.add((id: bId, name: cleanName, exe: normExe.isEmpty ? null : normExe, url: _extUrlForBrowser('$bId $rawId $cleanName')));
  }

  try {
    final today = DateTime.now();
    final from = today.subtract(const Duration(days: 30));
    String fmt(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final rows = metricsUsage.range(fmt(from), fmt(today));
    for (final r in rows) {
      final bId = Usage.browserIdForApp(r.app) ?? Usage.browserIdForApp(r.title);
      if (bId == null) continue;
      final exe = r.path.isNotEmpty && File(r.path).existsSync() ? r.path : null;
      final name = r.title.isNotEmpty ? r.title : prettyApp(r.app);
      if (exe != null || Platform.isMacOS) addTarget(r.app, name, exe);
    }
  } catch (_) {}

  if (Platform.isWindows) {
    try {
      final uc = Process.runSync('reg', ['query', r'HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice', '/v', 'ProgId']);
      if (uc.exitCode == 0) {
        final m = RegExp(r'ProgId\s+REG_SZ\s+(.+)').firstMatch(uc.stdout.toString());
        final progId = m?.group(1)?.trim() ?? '';
        if (progId.isNotEmpty) {
          final cmd = Process.runSync('reg', ['query', 'HKCR\\$progId\\shell\\open\\command', '/ve']);
          if (cmd.exitCode == 0) {
            final cm = RegExp(r'REG_SZ\s+"?([^"\r\n]+\.exe)', caseSensitive: false).firstMatch(cmd.stdout.toString());
            final exe = cm?.group(1)?.trim();
            if (exe != null && File(exe).existsSync()) {
              final base = exe.split(Platform.pathSeparator).last;
              addTarget(base, prettyApp(base), exe);
            }
          }
        }
      }
    } catch (_) {}

    final local = Platform.environment['LOCALAPPDATA'] ?? '';
    final pf = Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final pf86 = Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    final sep = Platform.pathSeparator;
    final candidates = <({String id, String name, List<String> paths})>[
      (id: 'opera', name: 'Opera GX', paths: ['$local${sep}Programs${sep}Opera GX${sep}opera.exe', '$local${sep}Programs${sep}Opera GX${sep}launcher.exe']),
      (id: 'opera', name: 'Opera', paths: ['$local${sep}Programs${sep}Opera${sep}opera.exe', '$pf${sep}Opera${sep}opera.exe']),
      (id: 'chrome', name: 'Google Chrome', paths: ['$pf${sep}Google${sep}Chrome${sep}Application${sep}chrome.exe', '$pf86${sep}Google${sep}Chrome${sep}Application${sep}chrome.exe', '$local${sep}Google${sep}Chrome${sep}Application${sep}chrome.exe']),
      (id: 'edge', name: 'Microsoft Edge', paths: ['$pf86${sep}Microsoft${sep}Edge${sep}Application${sep}msedge.exe', '$pf${sep}Microsoft${sep}Edge${sep}Application${sep}msedge.exe']),
      (id: 'brave', name: 'Brave Browser', paths: ['$pf${sep}BraveSoftware${sep}Brave-Browser${sep}Application${sep}brave.exe', '$local${sep}BraveSoftware${sep}Brave-Browser${sep}Application${sep}brave.exe']),
      (id: 'vivaldi', name: 'Vivaldi', paths: ['$local${sep}Vivaldi${sep}Application${sep}vivaldi.exe', '$pf${sep}Vivaldi${sep}Application${sep}vivaldi.exe']),
      (id: 'yandex', name: 'Yandex Browser', paths: ['$local${sep}Yandex${sep}YandexBrowser${sep}Application${sep}browser.exe']),
      (id: 'firefox', name: 'Mozilla Firefox', paths: ['$pf${sep}Mozilla Firefox${sep}firefox.exe', '$pf86${sep}Mozilla Firefox${sep}firefox.exe']),
      (id: 'firefox', name: 'Zen Browser', paths: ['$pf${sep}Zen Browser${sep}zen.exe', '$local${sep}Zen Browser${sep}zen.exe']),
      (id: 'firefox', name: 'LibreWolf', paths: ['$pf${sep}LibreWolf${sep}librewolf.exe']),
      (id: 'firefox', name: 'Floorp', paths: ['$pf${sep}Ablaze Floorp${sep}floorp.exe']),
      (id: 'firefox', name: 'Waterfox', paths: ['$pf${sep}Waterfox${sep}waterfox.exe']),
    ];
    for (final c in candidates) {
      for (final p in c.paths) {
        if (p.isNotEmpty && File(p).existsSync()) {
          addTarget(c.id, c.name, p);
          break;
        }
      }
    }
  } else if (Platform.isMacOS) {
    const macApps = <({String id, String app, String name})>[
      (id: 'opera', app: '/Applications/Opera GX.app', name: 'Opera GX'),
      (id: 'opera', app: '/Applications/Opera.app', name: 'Opera'),
      (id: 'chrome', app: '/Applications/Google Chrome.app', name: 'Google Chrome'),
      (id: 'edge', app: '/Applications/Microsoft Edge.app', name: 'Microsoft Edge'),
      (id: 'brave', app: '/Applications/Brave Browser.app', name: 'Brave Browser'),
      (id: 'vivaldi', app: '/Applications/Vivaldi.app', name: 'Vivaldi'),
      (id: 'arc', app: '/Applications/Arc.app', name: 'Arc'),
      (id: 'yandex', app: '/Applications/Yandex.app', name: 'Yandex'),
      (id: 'firefox', app: '/Applications/Firefox.app', name: 'Firefox'),
      (id: 'firefox', app: '/Applications/Zen Browser.app', name: 'Zen Browser'),
      (id: 'firefox', app: '/Applications/LibreWolf.app', name: 'LibreWolf'),
    ];
    for (final c in macApps) {
      if (Directory(c.app).existsSync()) addTarget(c.id, c.name, null);
    }
  } else if (Platform.isLinux) {
    const bins = <({String id, String bin, String name})>[
      (id: 'opera', bin: 'opera', name: 'Opera'),
      (id: 'chrome', bin: 'google-chrome', name: 'Google Chrome'),
      (id: 'chrome', bin: 'chromium', name: 'Chromium'),
      (id: 'chrome', bin: 'chromium-browser', name: 'Chromium'),
      (id: 'edge', bin: 'microsoft-edge', name: 'Microsoft Edge'),
      (id: 'brave', bin: 'brave-browser', name: 'Brave Browser'),
      (id: 'vivaldi', bin: 'vivaldi', name: 'Vivaldi'),
      (id: 'yandex', bin: 'yandex-browser', name: 'Yandex Browser'),
      (id: 'firefox', bin: 'firefox', name: 'Firefox'),
      (id: 'firefox', bin: 'librewolf', name: 'LibreWolf'),
      (id: 'firefox', bin: 'floorp', name: 'Floorp'),
      (id: 'firefox', bin: 'zen-browser', name: 'Zen Browser'),
    ];
    for (final c in bins) {
      try {
        final res = Process.runSync('which', [c.bin]);
        if (res.exitCode == 0) {
          final p = res.stdout.toString().trim().split('\n').first.trim();
          if (p.isNotEmpty) addTarget(c.id, c.name, p);
        }
      } catch (_) {}
    }
  }
  return out;
}

String updateStatus() {
  try {
    final f = File('${dataDir()}${Platform.pathSeparator}update.status');
    return f.existsSync() ? f.readAsStringSync().trim() : '';
  } catch (_) {
    return '';
  }
}
