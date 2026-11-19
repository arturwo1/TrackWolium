const fallbackRowsPerDay = 2500;
const minHistoryDays = 3;
const rowBaseBytes = 40;
const sysSamplesPerDay = 144;
const sysRamRowBytes = 24;
const sysDiskRowBytes = 28;
const defaultDiskCount = 2;
const forecastDays = 30;

const procMetricIds = ['cpu', 'ram', 'peak', 'ior', 'iow'];
const sysMetricIds = ['sysram', 'sysdisk'];
const allMetricIds = [...procMetricIds, ...sysMetricIds];

const fieldBytes = {'cpu': 3, 'ram': 4, 'peak': 3, 'ior': 4, 'iow': 4};

class Forecast {
  const Forecast({required this.rowsPerDay, required this.measured, required this.perMetric, required this.base, required this.total});

  final int rowsPerDay;
  final bool measured;
  final Map<String, int> perMetric;
  final int base;
  final int total;
}

int _rows(int histRows, int histDays) => histDays >= minHistoryDays && histRows > 0 ? (histRows / histDays).ceil() : fallbackRowsPerDay;

Forecast forecastDb({required Set<String> enabled, required int histRows, required int histDays, int disks = defaultDiskCount}) {
  final rows = _rows(histRows, histDays);
  final measured = histDays >= minHistoryDays && histRows > 0;
  final anyProc = procMetricIds.any(enabled.contains);
  final base = anyProc ? rows * forecastDays * rowBaseBytes : 0;
  final per = <String, int>{};
  var total = base;
  for (final m in allMetricIds) {
    final on = enabled.contains(m);
    final cost = metricCost(m, rows: rows, disks: disks);
    per[m] = cost;
    if (on) total += cost;
  }
  return Forecast(rowsPerDay: rows, measured: measured, perMetric: per, base: base, total: total);
}

int metricCost(String id, {required int rows, int disks = defaultDiskCount}) {
  switch (id) {
    case 'sysram':
      return sysSamplesPerDay * forecastDays * sysRamRowBytes;
    case 'sysdisk':
      return sysSamplesPerDay * forecastDays * sysDiskRowBytes * (disks < 1 ? 1 : disks);
    default:
      return rows * forecastDays * (fieldBytes[id] ?? 0);
  }
}

int baseCost(int rows) => rows * forecastDays * rowBaseBytes;

String formatSize(int bytes, List<String> units) {
  if (bytes <= 0) return '0 ${units[1]}';
  const k = 1024;
  if (bytes < k * k) return '${(bytes / k).ceil()} ${units[0]}';
  if (bytes < k * k * k) {
    final v = bytes / (k * k);
    return '${v < 10 ? v.toStringAsFixed(1) : v.round()} ${units[1]}';
  }
  final g = bytes / (k * k * k);
  return '${g < 10 ? g.toStringAsFixed(1) : g.round()} ${units[2]}';
}
