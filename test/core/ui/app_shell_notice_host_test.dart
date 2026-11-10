import 'package:dio/dio.dart';
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
import 'package:uten_imp/shared/models/user.dart';
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

  /// 只换会话身份（外壳 PlatformTablesHost 的 key 带 user.id）：与真实登录/
  /// 刷新后恢复会话触发同一次整棵重建，但不进入登录后路由与业务读取。
  void switchIdentity(AppUser user) => state = SessionState(user: user);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('com.uten.imp/desktop_window');

  Future<ProviderContainer> pumpShell(WidgetTester tester) async {
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
        // 离线客户端：身份切换会让导出纪元的弱监听重建客户端，实例化必须
        // 成功；任何真正发出的请求都按断网拒绝。
        apiClientProvider.overrideWithValue(
          ApiClient(
            Dio(BaseOptions(baseUrl: 'https://shell.fixture/api'))
              ..interceptors.add(
                InterceptorsWrapper(
                  onRequest: (options, handler) => handler.reject(
                    DioException(
                      requestOptions: options,
                      type: DioExceptionType.connectionError,
                      error: 'offline',
                    ),
                  ),
                ),
              ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const UtenApp()),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// 端到端一发事件，卡片应出现在真实外壳上；收尾推过完成态停留与退场，
  /// 收掉控制器自己的收起计时器。
  Future<void> expectEventShowsCard(WidgetTester tester) async {
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
    // 入场动画播完后卡片必须落在可见视口内、顶部居中（排除被摆出屏）。
    await tester.pump(const Duration(milliseconds: 300));
    final card = tester.getRect(find.byType(TableLoadProgressCard));
    const viewport = Rect.fromLTWH(0, 0, 1280, 800);
    expect(
      viewport.contains(card.topLeft) && viewport.contains(card.bottomRight),
      isTrue,
      reason: '卡片 $card 必须完整落在视口 $viewport 内',
    );
    expect(card.top, lessThan(80), reason: '卡片悬浮在页面顶部');
    expect(card.center.dx, closeTo(viewport.center.dx, 1), reason: '卡片水平居中');
    handle.finish(succeeded: true);
    await tester.pump();
    await tester.pump(
      tableLoadNoticeDoneHold + const Duration(milliseconds: 300),
    );
  }

  testWidgets('real UtenApp shell mounts the load progress notice host', (
    tester,
  ) async {
    await pumpShell(tester);

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
    await expectEventShowsCard(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('session identity switch remounts the shell subtree and the '
      'notice host stays attached', (tester) async {
    // 2026-11-09 网页端「始终看不到进度卡」真因：登录/刷新后恢复会话让
    // PlatformTablesHost（key 含 user.id）整棵重建；新宿主先 attach（已挂着
    // 则空操作），帧末旧宿主 dispose 又把共享控制器 detach——此后上报层
    // 无监听者，读取链按 hasListeners=false 根本不建进度任务。
    final container = await pumpShell(tester);
    expect(CompleteReadProgressReporter.hasListeners, isTrue);

    (container.read(sessionProvider.notifier) as _IdleSession).switchIdentity(
      const AppUser(id: 'shell-identity', code: 'shell', name: '外壳身份'),
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(TableLoadProgressNoticeHost),
      findsOneWidget,
      reason: '身份切换后外壳仍只挂一个进度宿主',
    );
    expect(
      CompleteReadProgressReporter.hasListeners,
      isTrue,
      reason: '身份切换重建外壳后上报层必须仍有监听者',
    );
    await expectEventShowsCard(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
