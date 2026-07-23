// 语言 Provider（中/英切换）
// 文档：docs/00-项目准则/05-国际化与多语言.md

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'shared_providers.dart';

/// 支持的语言列表
const supportedLocales = [Locale('zh'), Locale('en')];

class LocaleNotifier extends Notifier<Locale> {
  static const _key = 'locale';

  @override
  Locale build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final saved = prefs.getString(_key);
    if (saved == 'zh') return const Locale('zh');
    if (saved == 'en') return const Locale('en');

    final deviceLanguage = PlatformDispatcher.instance.locale.languageCode;
    return deviceLanguage == 'zh' ? const Locale('zh') : const Locale('en');
  }

  Future<void> set(Locale locale) async {
    await ref
        .read(sharedPreferencesProvider)
        .setString(_key, locale.languageCode);
    state = locale;
  }

  Future<void> toggle() async {
    final next = state.languageCode == 'zh'
        ? const Locale('en')
        : const Locale('zh');
    await set(next);
  }
}

final localeProvider = NotifierProvider<LocaleNotifier, Locale>(
  LocaleNotifier.new,
);
