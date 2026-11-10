import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/app.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/platform/desktop_window.dart';
import 'package:uten_imp/core/platform/platform_window_title.dart';
import 'package:uten_imp/core/maintenance/server_maintenance.dart';
import 'package:uten_imp/core/ui/table_load_progress_notice.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/shared/paging/complete_read_progress.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

/// 真实 UtenApp 外壳（2026-11-09 排查「网页端看不到进度卡」）：
/// 顶部 Stack 里的 TableLoadProgressNoticeHost 必须真的挂载并 attach 上报层，
/// 任何手动挂宿主的页面测试都替代不了这一环。装置沿用灾备导航测试的
/// 全量覆盖（离线会话 + 无探活/维护计时器），避免外壳后台计时器漏清。
class _QuietMaintenance extends ServerMaintenanceController {
  _QuietMaintenance({required super.read, required super.ready});
  @override
  Future<void> checkNow() async {}
}

class _IdleSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('com.uten.imp/desktop_window');

  testWidgets('real UtenApp shell mounts the load progress notice host', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    final controller = DesktopWindowController(enabled: true);
    final connection = ConnectionRecoveryController(
      probe: () async => true,
      probeDelays: const [Duration(seconds: 30)],
      probeDelayJitter: (delay) => delay,
    );
    final maintenance = _QuietMaintenance(
      read: () async => ServerMaintenanceSnapshot(
        phase: ServerMaintenancePhase.available,
        serverTime: DateTime.utc(2026, 11, 9),
      ),
      ready: () async => true,
    );
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() {
      controller.dispose();
      maintenance.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });

    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        sessionProvider.overrideWith(_IdleSession.new),
        apiBaseUrlProvider.overrideWithValue('https://shell.fixture/api'),
        desktopWindowControllerProvider.overrideWithValue(controller),
        connectionRecoveryProvider.overrideWith((ref) => connection),
        serverMaintenanceControllerProvider.overrideWithValue(maintenance),
        platformWindowTitleSyncProvider.overrideWith((ref) {}),
        platformBrandingSnapshotProvider.overrideWithValue(
          PlatformBranding.defaults,
        ),
        apiClientProvider.overrideWith((ref) => throw StateError('offline')),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const UtenApp()),
    );
    await tester.pumpAndSettle();

    // 1) 宿主真的在真实外壳树里。
    expect(
      find.byType(TableLoadProgressNoticeHost),
      findsOneWidget,
      reason: 'app.dart 顶部 Stack 必须挂载加载进度通知宿主',
    );
    // 2) 宿主 attach 了上报层：有监听者，读取链才会创建进度任务。
    expect(
      CompleteReadProgressReporter.hasListeners,
      isTrue,
      reason: '宿主挂载后 CompleteReadProgressReporter 必须有监听者',
    );
    // 3) 端到端一发事件，卡片应出现在真实外壳上。
    final handle = CompleteReadProgressReporter.start();
    await tester.pump();
    handle.update(loaded: 30, total: 300);
    await tester.pump();
    await tester.pump(
      tableLoadNoticeShowDelay + const Duration(milliseconds: 60),
    );
    expect(
      find.textContaining('正在加载数据：10%'),
      findsOneWidget,
      reason: '真实外壳中事件必须驱动卡片显示',
    );
    handle.finish(succeeded: true);
    await tester.pump();
    // 推过完成态停留与退场，收掉控制器自己的收起计时器。
    await tester.pump(
      tableLoadNoticeDoneHold + const Duration(milliseconds: 300),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
