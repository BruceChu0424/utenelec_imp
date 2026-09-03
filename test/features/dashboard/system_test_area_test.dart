// 工作台「系统测试」区 widget 测试：
// · 非超管不渲染；超管可见（默认收起，展开后见卡片与按钮）
// · 确认弹窗口令门禁：逐字输入「清空业务数据」才可提交
// · 失败路径：弹窗保持打开、可重试
// · 成功路径：弹窗关闭、调用仓库一次、本地登出并跳登录页
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/dashboard/repositories/system_test_repository.dart';
import 'package:uten_imp/features/dashboard/widgets/system_test_area.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

class _FakeRepository implements SystemTestRepository {
  _FakeRepository({this.result, this.error});

  final BusinessDataResetResult? result;
  final ApiException? error;
  int calls = 0;

  @override
  Future<BusinessDataResetResult> resetBusinessData() async {
    calls++;
    if (error != null) {
      throw error!;
    }
    return result!;
  }
}

class _TestSessionNotifier extends SessionNotifier {
  int logouts = 0;

  @override
  SessionState build() => const SessionState();

  @override
  Future<void> logout() async {
    logouts++;
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required bool superAdmin,
  required _FakeRepository repository,
  required _TestSessionNotifier notifier,
}) async {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: SystemTestArea()),
      ),
      GoRoute(
        path: RouteName.login,
        builder: (_, _) => const Scaffold(body: Center(child: Text('登录页'))),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        isSuperAdminProvider.overrideWithValue(superAdmin),
        systemTestRepositoryProvider.overrideWithValue(repository),
        sessionProvider.overrideWith(() => notifier),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _expandAndOpenDialog(WidgetTester tester) async {
  await tester.tap(find.text('系统测试'));
  await tester.pumpAndSettle();
  // 整卡点击直接弹确认窗（卡片上没有按钮）
  await tester.tap(find.byKey(const Key('system-test-clear-data-card')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('非超管不渲染系统测试区', (tester) async {
    await _pump(
      tester,
      superAdmin: false,
      repository: _FakeRepository(),
      notifier: _TestSessionNotifier(),
    );
    expect(find.text('系统测试'), findsNothing);
  });

  testWidgets('超管展开后可见清空数据卡片与按钮', (tester) async {
    await _pump(
      tester,
      superAdmin: true,
      repository: _FakeRepository(),
      notifier: _TestSessionNotifier(),
    );
    expect(find.text('系统测试'), findsOneWidget);
    await tester.tap(find.text('系统测试'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('system-test-clear-data-card')),
      findsOneWidget,
    );
    expect(find.text('清空数据'), findsOneWidget);
  });

  testWidgets('口令不匹配时禁止提交；逐字输入后放行', (tester) async {
    final repository = _FakeRepository(
      result: const BusinessDataResetResult(
        clearedTableCount: 222,
        clearedRows: 5,
        preservedTableCount: 96,
        authorizationEpochAfter: 2,
      ),
    );
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: _TestSessionNotifier(),
    );
    await _expandAndOpenDialog(tester);
    expect(
      find.byKey(const Key('system-test-clear-confirm-dialog')),
      findsOneWidget,
    );

    final submit = find.byKey(const Key('system-test-clear-confirm-submit'));
    await tester.enterText(
      find.byKey(const Key('system-test-clear-confirm-input')),
      '清空',
    );
    await tester.pump();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    // 未逐字匹配：请求未发出、弹窗仍在
    expect(repository.calls, 0);
    expect(
      find.byKey(const Key('system-test-clear-confirm-dialog')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('system-test-clear-confirm-input')),
      '清空业务数据',
    );
    await tester.pump();
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(repository.calls, 1);
    expect(
      find.byKey(const Key('system-test-clear-confirm-dialog')),
      findsNothing,
    );
  });

  testWidgets('清空失败：弹窗保持打开可重试', (tester) async {
    final repository = _FakeRepository(
      error: ApiException('CONFLICT', 'business_outbox 仍有 1 条待处理或失败事件'),
    );
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: _TestSessionNotifier(),
    );
    await _expandAndOpenDialog(tester);
    await tester.enterText(
      find.byKey(const Key('system-test-clear-confirm-input')),
      '清空业务数据',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('system-test-clear-confirm-submit')));
    await tester.pumpAndSettle();

    expect(repository.calls, 1);
    expect(
      find.byKey(const Key('system-test-clear-confirm-dialog')),
      findsOneWidget,
    );
  });

  testWidgets('清空成功：登出并跳登录页', (tester) async {
    final repository = _FakeRepository(
      result: const BusinessDataResetResult(
        clearedTableCount: 222,
        clearedRows: 5,
        preservedTableCount: 96,
        authorizationEpochAfter: 2,
      ),
    );
    final notifier = _TestSessionNotifier();
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: notifier,
    );
    await _expandAndOpenDialog(tester);
    await tester.enterText(
      find.byKey(const Key('system-test-clear-confirm-input')),
      '清空业务数据',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('system-test-clear-confirm-submit')));
    await tester.pumpAndSettle();

    expect(repository.calls, 1);
    expect(notifier.logouts, 1);
    expect(find.text('登录页'), findsOneWidget);
  });
}
