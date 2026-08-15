// 优腾综合管理平台 - 应用入口
// 文档：docs/05-架构/架构总览.md

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'shared/providers/shared_providers.dart';

/// 主 UI 字体预热：pubspec 声明的字体默认按需懒加载（尤其 Web，首次用到某字形才拉取），
/// 这在应用刚启动、字体还没下载完时打开的第一个弹窗/对话框里，会让文字短暂用系统兜底字体
/// 渲染、缺中文标点等字形（问题 #4：字体缺字"偶尔触发"——只在字体没加载完的窗口期出现，
/// 不是字体文件本身缺字，之前排查已确认 NotoSansSC.ttf 本身字形完整）。
/// 不 await：让它和登录页渲染并行下载，登录耗时通常已够它下载完，不拖慢首帧。
void _warmUpPrimaryFont() {
  final loader = FontLoader('NotoSansSC')
    ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
  unawaited(loader.load());
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _warmUpPrimaryFont();

  // Web 端屏蔽浏览器自带右键菜单：表格行右击要弹 App 自绘的上下文菜单
  // （UtenContextMenu），不屏蔽会两个菜单叠着出。桌面/移动端无此问题，仅 Web 调。
  if (kIsWeb) {
    unawaited(BrowserContextMenu.disableContextMenu());
  }

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
