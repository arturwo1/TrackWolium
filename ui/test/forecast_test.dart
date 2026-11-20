import 'package:flutter_test/flutter_test.dart';
import 'package:wolium/forecast.dart';

void main() {
  test('time only is small but not zero', () {
    final f = forecastDb(enabled: {}, histRows: 0, histDays: 0);
    expect(f.base, 0);
    expect(f.time, fallbackRowsPerDay * 30 * timeRowBytes);
    expect(f.total, f.time);
    expect(f.measured, false);
    expect(f.rowsPerDay, fallbackRowsPerDay);
    expect(formatSize(f.total, ['KB', 'MB', 'GB']), '0.4 MB');
  });

  test('time can be switched off', () {
    final f = forecastDb(enabled: {}, timeOn: false, histRows: 0, histDays: 0);
    expect(f.total, 0);
  });

  test('uses measured history when enough days', () {
    final f = forecastDb(enabled: {'cpu'}, histRows: 3000, histDays: 3);
    expect(f.measured, true);
    expect(f.rowsPerDay, 1000);
    expect(f.base, 1000 * 30 * rowBaseBytes);
    expect(f.total, f.base + f.time + 1000 * 30 * 3);
  });

  test('falls back to a constant on short history', () {
    final f = forecastDb(enabled: {'ram', 'peak'}, histRows: 100, histDays: 2);
    expect(f.measured, false);
    expect(f.rowsPerDay, fallbackRowsPerDay);
    expect(f.total, fallbackRowsPerDay * 30 * (rowBaseBytes + timeRowBytes + 4 + 3));
  });

  test('system metrics do not need the per process base', () {
    final f = forecastDb(enabled: {'sysram', 'sysdisk'}, histRows: 0, histDays: 0, disks: 3);
    expect(f.base, 0);
    expect(f.total, f.time + sysSamplesPerDay * 30 * sysRamRowBytes + sysSamplesPerDay * 30 * sysDiskRowBytes * 3);
  });

  test('formats sizes', () {
    const u = ['KB', 'MB', 'GB'];
    expect(formatSize(0, u), '0 MB');
    expect(formatSize(1500, u), '2 KB');
    expect(formatSize(400 * 1024, u), '0.4 MB');
    expect(formatSize(5 * 1024 * 1024, u), '5.0 MB');
    expect(formatSize(300 * 1024 * 1024, u), '300 MB');
    expect(formatSize(3 * 1024 * 1024 * 1024, u), '3.0 GB');
  });
}
