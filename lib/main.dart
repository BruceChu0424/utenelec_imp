// 优腾综合管理平台 - 应用入口
// 文档：docs/05-架构/架构总览.md

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/network/api_endpoint_configuration.dart';
import 'core/runtime/client_runtime_profile.dart';
import 'core/runtime/local_test_network.dart';
import 'core/runtime/native_runtime_identity.dart';
import 'core/runtime/local_test_storage.dart';
import 'core/runtime/bootstrap_trace.dart';
import 'core/diagnostics/diagnostic_log.dart';
import 'core/network/company_tls.dart';
import 'core/responsive/display_zoom_pointer_binding.dart';
import 'core/web/browser_drop_guard.dart';
import 'core/web_update/web_update_bridge.dart';
import 'core/web_update/web_update_safety.dart';
import 'shared/providers/shared_providers.dart';

final _localBootstrapStatus = ValueNotifier<String>('正在验证本地测试环境');
String _localBootstrapPhase = 'configuration';

Future<T> _bootstrapStep<T>(String phase, Future<T> Function() action) async {
  if (!ClientRuntimeProfile.isLocalTest) return action();
  _localBootstrapPhase = phase;
  _localBootstrapStatus.value = '正在验证：$phase';
  recordLocalBootstrapPhase('$phase.begin');
  try {
    final value = await action().timeout(const Duration(seconds: 12));
    recordLocalBootstrapPhase('$phase.end');
    return value;
  } catch (error) {
    recordLocalBootstrapPhase('$phase.failed.${error.runtimeType}');
    rethrow;
  }
}

class _LocalTestBootstrapView extends StatelessWidget {
  const _LocalTestBootstrapView();
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ValueListenableBuilder<String>(
              valueListenable: _localBootstrapStatus,
              builder: (_, status, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('UTEN 本地测试', style: TextStyle(fontSize: 22)),
                  const SizedBox(height: 16),
                  Text(status, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  const Text('隔离验证完成前不加载账号或进入业务系统。'),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

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

Future<void> main() => bootstrapUtenApp();

/// Shares the exact app startup with local diagnostic entrypoints.
/// Normal startup keeps the production pointer-aware binding.
@visibleForTesting
Future<void> bootstrapUtenApp({
  WidgetsFlutterBinding Function()? bindingFactory,
}) async {
  recordLocalBootstrapPhase('binding.begin');
  // 在任何插件/默认 binding 初始化之前启用整体缩放的滚轮坐标换算。
  (bindingFactory ?? UtenWidgetsFlutterBinding.new)();
  recordLocalBootstrapPhase('binding.end');
  if (ClientRuntimeProfile.isLocalTest) runApp(const _LocalTestBootstrapView());
  late final SharedPreferences prefs;
  try {
    ClientRuntimeProfile.current.validateConfiguration(
      local: configuredLocalApiBaseUrl,
      cloud: configuredCloudApiBaseUrl,
      controlPlane: const String.fromEnvironment('DR_CONTROL_PLANE_URL'),
    );
    installLocalTestNetworkBoundary(localApi: configuredLocalApiBaseUrl);
    await _bootstrapStep('native_identity', verifyNativeRuntimeIdentity);
    await _bootstrapStep('private_paths', verifyLocalTestStorage);
    await _bootstrapStep('diagnostics', AppDiagnostics.initialize);
    _warmUpPrimaryFont();
    AppDiagnostics.record('startup.phase', fields: {'phase': 'tls'});
    await _bootstrapStep('tls', initializeCompanyTls);

    // Web 端屏蔽浏览器自带右键菜单：表格行右击要弹 App 自绘的上下文菜单
    // （UtenContextMenu），不屏蔽会两个菜单叠着出。桌面/移动端无此问题，仅 Web 调。
    if (kIsWeb) {
      unawaited(BrowserContextMenu.disableContextMenu());
      // 拖文件到页面非接收区时，浏览器默认会打开该文件把整个应用顶掉，一并屏蔽。
      installBrowserDropGuard();
      installWebUpdateSafetyBridge();
    }

    // 初始化 SharedPreferences（用于偏好持久化）
    AppDiagnostics.record('startup.phase', fields: {'phase': 'preferences'});
    prefs = await _bootstrapStep('preferences', SharedPreferences.getInstance);
  } catch (error) {
    if (!ClientRuntimeProfile.isLocalTest) rethrow;
    _localBootstrapStatus.value =
        '启动隔离验证未通过\n阶段：$_localBootstrapPhase\n类型：${error.runtimeType}\n未进入业务系统';
    return;
  }

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
  WidgetsBinding.instance.addPostFrameCallback((_) {
    AppDiagnostics.record('startup.phase', fields: {'phase': 'ready'});
    webUpdateSafety.setReady(true);
  });
}
