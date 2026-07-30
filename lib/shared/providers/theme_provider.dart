// 主题 Provider（深/浅切换）
// 文档：docs/00-项目准则/08-主题与配色.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'shared_providers.dart';

/// 主题模式：light / dark / system
///
/// 注意：不要在 build() 里给 `late final` 字段赋值——Riverpod 2 的 Notifier
/// 在依赖变化时复用实例重新调用 build()，二次赋值会抛 LateInitializationError。
/// 改为直接通过 ref.read 读取即可（同步 Provider，零开销）。
class ThemeNotifier extends Notifier<ThemeMode> {
  static const _key = 'themeMode';

  @override
  ThemeMode build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final saved = prefs.getString(_key);
    return switch (saved) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> set(ThemeMode mode) async {
    await ref.read(sharedPreferencesProvider).setString(_key, mode.name);
    state = mode;
  }

  Future<void> toggle() async {
    final next = state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    await set(next);
  }
}

final themeProvider = NotifierProvider<ThemeNotifier, ThemeMode>(
  ThemeNotifier.new,
);
