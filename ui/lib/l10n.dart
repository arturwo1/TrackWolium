import 'dart:io';
import 'package:flutter/foundation.dart';
import 'lang_data.g.dart';

export 'lang_data.g.dart' show languages;

String detectLanguage() {
  final name = Platform.localeName.toLowerCase().replaceAll('_', '-');
  for (final code in languages.keys) {
    final c = code.toLowerCase();
    if (name == c || name.startsWith('$c-')) return code;
  }
  for (final code in languages.keys) {
    if (name.startsWith(code.split('-').first.toLowerCase())) return code;
  }
  return 'en';
}

final ValueNotifier<String> language = ValueNotifier<String>(detectLanguage());

String tr(String key) => strings[language.value]?[key] ?? strings['en']![key] ?? key;
