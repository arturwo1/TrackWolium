import 'dart:convert';
import 'dart:io';
import 'data.dart';

class DiscordInstance {
  DiscordInstance(this.kind, this.pids, this.launch, this.app);

  final String kind;
  final List<int> pids;
  final List<String> launch;
  final String app;
}

const _names = {'discord', 'discordptb', 'discordcanary', 'discorddevelopment', 'discord ptb', 'discord canary', 'discord development'};

Future<bool> _hasCommand(String name) async {
  try {
    final r = await Process.run('sh', ['-c', 'command -v $name']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<DiscordInstance?> findDiscord() => Platform.isMacOS ? _findMac() : _findLinux();

Future<DiscordInstance?> _findMac() async {
  try {
    final r = await Process.run('ps', ['-axo', 'pid=,comm=']);
    if (r.exitCode != 0) return null;
    const marker = '.app/Contents/MacOS/';
    final pids = <int>[];
    String? bundle;
    for (final raw in LineSplitter.split(r.stdout as String)) {
      final line = raw.trim();
      final space = line.indexOf(' ');
      if (space < 0) continue;
      final pid = int.tryParse(line.substring(0, space));
      final path = line.substring(space + 1).trim();
      final at = path.indexOf(marker);
      if (pid == null || at < 0 || at != path.lastIndexOf(marker)) continue;
      if (!_names.contains(path.split('/').last.toLowerCase())) continue;
      pids.add(pid);
      bundle ??= path.substring(0, at + 4);
    }
    if (bundle == null) return null;
    return DiscordInstance('mac', pids, ['open', '-a', bundle], bundle);
  } catch (_) {
    return null;
  }
}

Future<DiscordInstance?> _findLinux() async {
  try {
    if (await _hasCommand('flatpak')) {
      final r = await Process.run('flatpak', ['ps', '--columns=application']);
      if (r.exitCode == 0) {
        for (final line in LineSplitter.split(r.stdout as String)) {
          final app = line.trim();
          if (app.startsWith('com.discordapp.')) return DiscordInstance('flatpak', [], ['flatpak', 'run', app], app);
        }
      }
    }
  } catch (_) {}
  final found = <int, List<String>>{};
  final exes = <int, String>{};
  try {
    for (final entry in Directory('/proc').listSync(followLinks: false)) {
      final segments = entry.path.split('/');
      final id = int.tryParse(segments.last);
      if (id == null) continue;
      try {
        final exe = Link('/proc/$id/exe').targetSync().replaceAll(' (deleted)', '');
        if (!_names.contains(exe.split('/').last.toLowerCase())) continue;
        final args = utf8.decode(File('/proc/$id/cmdline').readAsBytesSync(), allowMalformed: true).split('\u0000').where((e) => e.isNotEmpty).toList();
        found[id] = args;
        exes[id] = exe;
      } catch (_) {}
    }
  } catch (_) {}
  if (found.isEmpty) return null;
  final mains = found.keys.where((id) => !found[id]!.any((a) => a.startsWith('--type='))).toList();
  if (mains.isEmpty) return null;
  final main = mains.first;
  final exe = exes[main]!;
  final snap = RegExp(r'^/snap/([^/]+)/').firstMatch(exe);
  if (snap != null) return DiscordInstance('snap', found.keys.toList(), ['snap', 'run', snap.group(1)!], snap.group(1)!);
  final args = found[main]!.skip(1).toList();
  return DiscordInstance('native', found.keys.toList(), [exe, ...args], exe);
}

Future<bool> _alive(int pid) async {
  if (Platform.isLinux) return Directory('/proc/$pid').existsSync();
  try {
    final r = await Process.run('kill', ['-0', '$pid']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<void> stopDiscord(DiscordInstance d) async {
  if (d.kind == 'flatpak') {
    await Process.run('flatpak', ['kill', d.app]);
    for (var i = 0; i < 40; i++) {
      final r = await Process.run('flatpak', ['ps', '--columns=application']);
      if (!(r.stdout as String).contains(d.app)) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return;
  }
  for (final pid in d.pids) {
    Process.killPid(pid);
  }
  for (var i = 0; i < 40; i++) {
    var any = false;
    for (final pid in d.pids) {
      if (await _alive(pid)) any = true;
    }
    if (!any) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  for (final pid in d.pids) {
    Process.killPid(pid, ProcessSignal.sigkill);
  }
  await Future<void>.delayed(const Duration(milliseconds: 500));
}

Future<void> _waitForSocket() async {
  final file = File('${dataDir()}${Platform.pathSeparator}discordrpc.status');
  for (var i = 0; i < 60; i++) {
    try {
      final v = file.existsSync() ? file.readAsStringSync().trim() : '';
      if (v == 'listening' || v == 'active') return;
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

Future<void> startDiscord(DiscordInstance d) async {
  if (d.kind == 'mac') {
    await Process.run('open', ['-a', d.app]);
    return;
  }
  await Process.start(d.launch.first, d.launch.skip(1).toList(), mode: ProcessStartMode.detached);
}

Future<bool> restartDiscordPosix() async {
  final d = await findDiscord();
  if (d == null) return false;
  await stopDiscord(d);
  await _waitForSocket();
  await Future<void>.delayed(const Duration(seconds: 1));
  await startDiscord(d);
  return true;
}
