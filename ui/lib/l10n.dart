import 'dart:io';
import 'package:flutter/foundation.dart';

const languages = {'en': 'English', 'ru': 'Русский'};

const _strings = {
  'en': {
    'brandSub': 'Activity tracker',
    'navActivity': 'Activity',
    'navSettings': 'Settings',
    'website': 'Website',
    'welcome': 'Wolium tracks how long your apps are open and in focus. Data is stored only in the program folder on this computer.',
    'privacy': 'Privacy policy',
    'accept': 'Accept',
    'serviceMissing': 'The service is not running. Start trackwolium.exe.',
    'serviceStale': 'The service is not responding, data is not updating.',
    'noData': 'No data yet',
    'date': 'Date',
    'app': 'App',
    'focused': 'Focused',
    'open': 'Open',
    'minimized': 'Minimized',
    'background': 'Background',
    'autostart': 'Start with Windows',
    'dataFolder': 'Data folder',
    'language': 'Language',
    'unitS': 's',
    'unitM': 'm',
    'unitH': 'h',
  },
  'ru': {
    'brandSub': 'Трекер активности',
    'navActivity': 'Активность',
    'navSettings': 'Настройки',
    'website': 'Сайт',
    'welcome': 'Wolium считает, сколько времени твои приложения открыты и в фокусе. Данные хранятся только в папке программы на этом компьютере.',
    'privacy': 'Политика конфиденциальности',
    'accept': 'Принимаю',
    'serviceMissing': 'Служба не запущена. Запусти trackwolium.exe.',
    'serviceStale': 'Служба не отвечает, данные не обновляются.',
    'noData': 'Пока нет данных',
    'date': 'Дата',
    'app': 'Приложение',
    'focused': 'В фокусе',
    'open': 'Открыто',
    'minimized': 'Свёрнуто',
    'background': 'Фон',
    'autostart': 'Запускать вместе с Windows',
    'dataFolder': 'Папка с данными',
    'language': 'Язык',
    'unitS': 'с',
    'unitM': 'м',
    'unitH': 'ч',
  },
};

String detectLanguage() {
  final name = Platform.localeName.toLowerCase();
  return name.startsWith('ru') ? 'ru' : 'en';
}

final ValueNotifier<String> language = ValueNotifier<String>(detectLanguage());

String tr(String key) => _strings[language.value]?[key] ?? _strings['en']![key] ?? key;
