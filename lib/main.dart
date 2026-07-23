// 优腾综合管理平台 - 应用入口
// 文档：docs/05-架构/架构总览.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'shared/providers/shared_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化 SharedPreferences（用于偏好持久化）
  final prefs = await SharedPreferences.getInstance();

  runApp(
    ProviderScope(
      overrides: [
        // 把 prefs 注入到全局 sharedPreferencesProvider
        // 所有偏好 Provider（theme/locale/fontScale/performance）都从这里读
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const UtenApp(),
    ),
  );
}
