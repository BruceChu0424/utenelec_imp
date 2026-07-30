import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'shared_providers.dart';

/// 支持的语言列表
const chinaLocale = Locale('zh', 'CN');
const englishLocale = Locale('en', 'US');
const supportedLocales = [chinaLocale, englishLocale];

class LocaleNotifier extends Notifier<Locale> {
  static const _key = 'locale';

  @override
  Locale build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final saved = prefs.getString(_key);
    final locale = switch (saved) {
      'en' || 'en_US' || 'en-US' => englishLocale,
      // 兼容历史保存值；首次启动也固定简体中文，不被英文系统语言误导。
      _ => chinaLocale,
    };
    Intl.defaultLocale = locale.toString();
    return locale;
  }

  Future<void> set(Locale locale) async {
    final normalized = locale.languageCode == 'en'
        ? englishLocale
        : chinaLocale;
    await ref
        .read(sharedPreferencesProvider)
        .setString(_key, normalized.toString());
    Intl.defaultLocale = normalized.toString();
    state = normalized;
  }

  Future<void> toggle() async {
    final next = state.languageCode == 'zh' ? englishLocale : chinaLocale;
    await set(next);
  }
}

final localeProvider = NotifierProvider<LocaleNotifier, Locale>(
  LocaleNotifier.new,
);
