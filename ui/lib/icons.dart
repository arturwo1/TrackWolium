import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'theme.dart';

final DynamicLibrary? _shell = Platform.isWindows ? DynamicLibrary.open('shell32.dll') : null;
final DynamicLibrary? _user = Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;
final DynamicLibrary? _gdi = Platform.isWindows ? DynamicLibrary.open('gdi32.dll') : null;

final _extract = _shell?.lookupFunction<Uint32 Function(Pointer<Utf16>, Int32, Pointer<IntPtr>, Pointer<IntPtr>, Uint32), int Function(Pointer<Utf16>, int, Pointer<IntPtr>, Pointer<IntPtr>, int)>('ExtractIconExW');
final _getIconInfo = _user?.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>('GetIconInfo');
final _destroyIcon = _user?.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DestroyIcon');
final _getDc = _user?.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GetDC');
final _releaseDc = _user?.lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>('ReleaseDC');
final _getObject = _gdi?.lookupFunction<Int32 Function(IntPtr, Int32, Pointer<Uint8>), int Function(int, int, Pointer<Uint8>)>('GetObjectW');
final _getDibits = _gdi?.lookupFunction<Int32 Function(IntPtr, IntPtr, Uint32, Uint32, Pointer<Uint8>, Pointer<Uint8>, Uint32), int Function(int, int, int, int, Pointer<Uint8>, Pointer<Uint8>, int)>('GetDIBits');
final _deleteObject = _gdi?.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteObject');

Uint8List? _bitmapPixels(int bitmap, int w, int h, int dc) {
  final bmi = calloc<Uint8>(44);
  final pixels = calloc<Uint8>(w * h * 4);
  try {
    final head = bmi.cast<Int32>();
    head[0] = 40;
    head[1] = w;
    head[2] = -h;
    bmi.elementAt(12).cast<Uint16>().value = 1;
    bmi.elementAt(14).cast<Uint16>().value = 32;
    final got = _getDibits!(dc, bitmap, 0, h, pixels, bmi, 0);
    if (got == 0) return null;
    return Uint8List.fromList(pixels.asTypedList(w * h * 4));
  } finally {
    calloc.free(bmi);
    calloc.free(pixels);
  }
}

Uint8List? _extractRgba(String path, List<int> size) {
  if (_extract == null) return null;
  final p = path.toNativeUtf16();
  final small = calloc<IntPtr>();
  try {
    final n = _extract!(p, 0, nullptr, small, 1);
    if (n == 0 || small.value == 0) return null;
    final icon = small.value;
    final info = calloc<Uint8>(32);
    final bm = calloc<Uint8>(32);
    final dc = _getDc!(0);
    try {
      if (_getIconInfo!(icon, info) == 0) return null;
      final words = info.cast<Int64>();
      final mask = words[2];
      final color = words[3];
      try {
        if (color == 0) return null;
        _getObject!(color, 32, bm);
        final ints = bm.cast<Int32>();
        final w = ints[1];
        final h = ints[2];
        if (w <= 0 || h <= 0 || w > 256 || h > 256) return null;
        final px = _bitmapPixels(color, w, h, dc);
        if (px == null) return null;
        var hasAlpha = false;
        for (var i = 3; i < px.length; i += 4) {
          if (px[i] != 0) {
            hasAlpha = true;
            break;
          }
        }
        Uint8List? m;
        if (!hasAlpha && mask != 0) m = _bitmapPixels(mask, w, h, dc);
        final out = Uint8List(px.length);
        for (var i = 0; i < px.length; i += 4) {
          out[i] = px[i + 2];
          out[i + 1] = px[i + 1];
          out[i + 2] = px[i];
          out[i + 3] = hasAlpha ? px[i + 3] : (m != null && m[i] != 0 ? 0 : 255);
        }
        size
          ..clear()
          ..addAll([w, h]);
        return out;
      } finally {
        if (mask != 0) _deleteObject!(mask);
        if (color != 0) _deleteObject!(color);
      }
    } finally {
      _releaseDc!(0, dc);
      _destroyIcon!(icon);
      calloc.free(info);
      calloc.free(bm);
    }
  } catch (_) {
    return null;
  } finally {
    calloc.free(p);
    calloc.free(small);
  }
}

final List<int> _crcTable = List.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
  }
  return c;
});

int _crc(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

Uint8List _chunk(String type, List<int> data) {
  final body = <int>[...type.codeUnits, ...data];
  final out = BytesBuilder();
  final len = ByteData(4)..setUint32(0, data.length);
  out.add(len.buffer.asUint8List());
  out.add(body);
  final crc = ByteData(4)..setUint32(0, _crc(body));
  out.add(crc.buffer.asUint8List());
  return out.toBytes();
}

Uint8List _png(Uint8List rgba, int w, int h) {
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0);
    raw.add(rgba.sublist(y * w * 4, (y + 1) * w * 4));
  }
  final head = ByteData(13)
    ..setUint32(0, w)
    ..setUint32(4, h)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  final out = BytesBuilder();
  out.add([137, 80, 78, 71, 13, 10, 26, 10]);
  out.add(_chunk('IHDR', head.buffer.asUint8List()));
  out.add(_chunk('IDAT', zlib.encode(raw.toBytes())));
  out.add(_chunk('IEND', const []));
  return out.toBytes();
}

final Map<String, Uint8List?> _cache = {};

Uint8List? iconPng(String path) {
  if (path.isEmpty || !Platform.isWindows) return null;
  if (_cache.containsKey(path)) return _cache[path];
  Uint8List? result;
  try {
    final size = <int>[];
    final rgba = _extractRgba(path, size);
    if (rgba != null) result = _png(rgba, size[0], size[1]);
  } catch (_) {}
  _cache[path] = result;
  return result;
}

class AppIcon extends StatelessWidget {
  const AppIcon({super.key, required this.title, required this.path, this.size = 20});

  final String title;
  final String path;
  final double size;

  @override
  Widget build(BuildContext context) {
    final png = iconPng(path);
    if (png != null) {
      return Image.memory(png, width: size, height: size, filterQuality: FilterQuality.medium, gaplessPlayback: true);
    }
    final letter = title.isEmpty ? '?' : String.fromCharCode(title.runes.first).toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: cSoft, borderRadius: BorderRadius.circular(size * 0.28), border: Border.fromBorderSide(line)),
      child: Text(letter, style: TextStyle(color: cPrimary, fontWeight: FontWeight.w800, fontSize: size * 0.55, height: 1)),
    );
  }
}
