import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'data.dart';

const siteUrl = 'https://wolium.netlify.app/';
const privacyUrl = 'https://wolium.netlify.app/privacy-policy/';

void main() {
  runApp(const WoliumApp());
}

class WoliumApp extends StatelessWidget {
  const WoliumApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wolium',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF14A098), brightness: Brightness.dark, useMaterial3: true),
      home: const Root(),
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
    if (!accepted) {
      return Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Wolium', style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 12),
                  const Text('Wolium tracks how long your apps are open and in focus. Data is stored only in the program folder on this computer.'),
                  const SizedBox(height: 12),
                  TextButton(onPressed: () => open(privacyUrl), child: const Text('Privacy policy')),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () {
                      settings.accepted = true;
                      setState(() => accepted = true);
                    },
                    child: const Text('Accept'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return const Home();
  }
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
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

  Widget table() {
    if (!hasDb) return const Center(child: Text('The service is not running. Start trackwolium.exe.'));
    if (rows.isEmpty) return const Center(child: Text('No data yet'));
    const head = TextStyle(fontWeight: FontWeight.w600);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(children: [
          const Text('Date', style: head),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: day,
            items: [for (final d in days) DropdownMenuItem(value: d, child: Text(d))],
            onChanged: (v) {
              day = v;
              refresh();
            },
          ),
        ]),
        const SizedBox(height: 8),
        Table(
          columnWidths: const {0: FlexColumnWidth(3)},
          children: [
            const TableRow(children: [
              Padding(padding: EdgeInsets.all(6), child: Text('App', style: head)),
              Padding(padding: EdgeInsets.all(6), child: Text('Focused', style: head)),
              Padding(padding: EdgeInsets.all(6), child: Text('Open', style: head)),
              Padding(padding: EdgeInsets.all(6), child: Text('Minimized', style: head)),
              Padding(padding: EdgeInsets.all(6), child: Text('Background', style: head)),
            ]),
            for (final r in rows)
              TableRow(children: [
                Padding(padding: const EdgeInsets.all(6), child: Text(r.app, overflow: TextOverflow.ellipsis)),
                for (final i in [0, 1, 2, 3]) Padding(padding: const EdgeInsets.all(6), child: Text(r.ms[i] == 0 ? '-' : formatMs(r.ms[i]))),
              ]),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [table(), const SettingsPage()];
    return Scaffold(
      appBar: AppBar(title: const Text('Wolium'), actions: [
        TextButton(onPressed: () => open(siteUrl), child: const Text('Website')),
      ]),
      body: Column(children: [
        if (serviceDown)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.errorContainer,
            padding: const EdgeInsets.all(8),
            child: const Text('The service is not responding, data is not updating.'),
          ),
        Expanded(child: pages[tab]),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Time'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
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
    return ListView(padding: const EdgeInsets.all(16), children: [
      SwitchListTile(
        title: const Text('Start with Windows'),
        value: auto ?? false,
        onChanged: auto == null
            ? null
            : (v) async {
                await setAutostart(v);
                final now = await autostartEnabled();
                if (mounted) setState(() => auto = now);
              },
      ),
      ListTile(title: const Text('Privacy policy'), onTap: () => open(privacyUrl)),
      ListTile(title: const Text('Data folder'), subtitle: Text(dataDir())),
    ]);
  }
}
