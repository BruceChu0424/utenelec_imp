// 工作台「系统测试」区 widget 测试：
// · 非超管不渲染；超管可见（默认收起，展开后见卡片与按钮）
// · 确认弹窗口令门禁：逐字输入「清空业务数据」才可提交
// · 附件：有未清理文件仍可清空（服务端自动清理）；预览失败（非 FORBIDDEN）仍可提交；
//   预览 FORBIDDEN（运行开关未开启）显示后端原话并保持禁用；可选分批清理弹窗需独立强确认
// · 失败路径：弹窗保持打开、可重试；超时路径：提示「可能仍在后台执行」、不登出
// · 成功路径：弹窗关闭、调用仓库一次、本地登出并跳登录页
// · 展开后回显上次清空结果（重登后可见）
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

  /// NetworkTimeoutException 也是 ApiException 子类，可直接放这里。
  final ApiException? error;
  int calls = 0;
  int previewCalls = 0;
  int filePrepareCalls = 0;
  BusinessAttachmentResetPreview? files;
  ApiException? previewError;
  ApiException? preparationError;
  BusinessAttachmentResetPreview? submittedPreview;
  BusinessDataResetLastResult lastResult = BusinessDataResetLastResult.none;

  @override
  Future<BusinessAttachmentResetPreview> previewBusinessAttachments() async {
    previewCalls++;
    if (previewError != null) throw previewError!;
    return files ??
        const BusinessAttachmentResetPreview(
          database: 'test',
          fingerprint: 'test',
          blockingCount: 0,
        );
  }

  @override
  Future<BusinessAttachmentResetPreview> prepareBusinessAttachments(
    BusinessAttachmentResetPreview preview,
  ) async {
    filePrepareCalls++;
    submittedPreview = preview;
    if (preparationError != null) throw preparationError!;
    return files ?? preview;
  }

  @override
  Future<BusinessDataResetResult> resetBusinessData() async {
    calls++;
    if (error != null) {
      throw error!;
    }
    return result!;
  }

  @override
  Future<BusinessDataResetLastResult> lastBusinessDataResetResult() async =>
      lastResult;
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

const _okResult = BusinessDataResetResult(
  clearedTableCount: 222,
  clearedRows: 5,
  preservedTableCount: 96,
  authorizationEpochAfter: 2,
  deletedAttachmentFiles: 3,
);

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

Future<void> _typePhraseAndSubmit(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('system-test-clear-confirm-input')),
    '清空业务数据',
  );
  await tester.pump();
  await tester.tap(find.byKey(const Key('system-test-clear-confirm-submit')));
  await tester.pumpAndSettle();
}

void main() {
  const blockedFiles = BusinessAttachmentResetPreview(
    database: 'local_test',
    fingerprint: 'reviewed-objects',
    blockingCount: 1,
    items: [
      {
        'type': 'ATTACHMENT',
        'id': 'file-a',
        'ownerType': 'SALES_ORDER',
        'ownerId': 'order-a',
        'fileName': '合同原件.pdf',
        'state': 'CLEAN',
        'message': '文件仍在使用，需先确认删除',
      },
    ],
  );

  testWidgets('有未清理文件时仍可清空；可选分批清理需独立强确认且绑定预览', (tester) async {
    final repository = _FakeRepository()..files = blockedFiles;
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
    // 2026-09-09 口径：业务文件由清空流程自动一并删除，blocking 只是提示，
    // 确认按钮保持可点（此前被 blocking>0 锁死导致内网无法清空）。
    expect(find.textContaining('将随本次清空一并删除'), findsOneWidget);
    await tester.tap(find.text('先分批清理附件（可选）'));
    await tester.pumpAndSettle();
    expect(find.text('合同原件.pdf'), findsOneWidget);
    expect(find.text('目标数据库：local_test'), findsOneWidget);
    final input = find.byKey(const Key('business-attachment-prepare-confirm'));
    final submit = find.byKey(const Key('business-attachment-prepare-submit'));
    await tester.enterText(input, '清理');
    await tester.pump();
    await tester.tap(submit);
    expect(repository.filePrepareCalls, 0);
    await tester.enterText(input, '清理测试业务附件');
    await tester.pump();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(repository.filePrepareCalls, 1);
    expect(repository.submittedPreview!.fingerprint, 'reviewed-objects');
    expect(repository.calls, 0);
    expect(find.textContaining('1 项业务文件'), findsOneWidget);
    repository.files = const BusinessAttachmentResetPreview(
      database: 'local_test',
      fingerprint: 'finished',
      blockingCount: 0,
    );
    await tester.tap(find.text('刷新核对'));
    await tester.pumpAndSettle();
    expect(find.textContaining('文件已核对完成'), findsOneWidget);
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(find.text('先分批清理附件（可选）'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有未清理文件（blocking>0）：确认按钮可点，清空请求发出一次', (tester) async {
    final repository = _FakeRepository(result: _okResult)..files = blockedFiles;
    final notifier = _TestSessionNotifier();
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: notifier,
    );
    await _expandAndOpenDialog(tester);
    expect(find.textContaining('1 项业务文件'), findsOneWidget);
    await _typePhraseAndSubmit(tester);
    expect(repository.calls, 1);
    expect(repository.filePrepareCalls, 0);
    expect(notifier.logouts, 1);
    expect(find.text('登录页'), findsOneWidget);
  });

  testWidgets('附件预览失败（非 FORBIDDEN）：提示清空时自动清理，仍可提交', (tester) async {
    final repository = _FakeRepository(result: _okResult)
      ..previewError = ApiException('INTERNAL', '服务器繁忙，请稍后再试');
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: _TestSessionNotifier(),
    );
    await _expandAndOpenDialog(tester);
    expect(find.textContaining('清空时仍会自动清理'), findsOneWidget);
    expect(find.text('服务器繁忙，请稍后再试'), findsNothing);
    await _typePhraseAndSubmit(tester);
    expect(repository.calls, 1);
    expect(
      find.byKey(const Key('system-test-clear-confirm-dialog')),
      findsNothing,
    );
  });

  testWidgets('附件预览 FORBIDDEN（运行开关未开启）：显示后端原话并保持禁用', (tester) async {
    const backendMessage = '当前环境未开启业务数据清空（仅本地开发库与内网测试服务器可用）';
    final repository = _FakeRepository(result: _okResult)
      ..previewError = ApiException('FORBIDDEN', backendMessage);
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: _TestSessionNotifier(),
    );
    await _expandAndOpenDialog(tester);
    expect(find.text(backendMessage), findsOneWidget);
    expect(find.textContaining('清空时仍会自动清理'), findsNothing);
    await _typePhraseAndSubmit(tester);
    expect(repository.calls, 0);
    expect(
      find.byKey(const Key('system-test-clear-confirm-dialog')),
      findsOneWidget,
    );
    // 「重新核对附件」可重试：开关打开后预览成功即放行
    repository.previewError = null;
    await tester.tap(find.text('重新核对附件'));
    await tester.pumpAndSettle();
    expect(repository.previewCalls, 2);
    await _typePhraseAndSubmit(tester);
    expect(repository.calls, 1);
  });

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

  testWidgets('展开系统测试区后回显上次清空结果（收起时不读取）', (tester) async {
    final repository = _FakeRepository()
      ..lastResult = BusinessDataResetLastResult(
        available: true,
        finishedAt: DateTime.utc(2026, 9, 10, 4),
        operatorAccount: 'admin',
        clearedTableCount: 266,
        clearedRows: 12,
        preservedTableCount: 96,
        authorizationEpochAfter: 380,
        deletedAttachmentFiles: 3,
      );
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: _TestSessionNotifier(),
    );
    expect(
      find.byKey(const Key('system-test-last-reset-result')),
      findsNothing,
    );
    await tester.tap(find.text('系统测试'));
    await tester.pumpAndSettle();
    final line = find.byKey(const Key('system-test-last-reset-result'));
    expect(line, findsOneWidget);
    final text = tester.widget<Text>(line).data!;
    expect(text, contains('上次清空：'));
    expect(text, contains('由 admin 执行'));
    expect(text, contains('清空 266 张业务表（12 行）'));
    expect(text, contains('物理删除附件文件 3 个'));
  });

  testWidgets('口令不匹配时禁止提交；逐字输入后放行', (tester) async {
    final repository = _FakeRepository(result: _okResult);
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
    await _typePhraseAndSubmit(tester);

    expect(repository.calls, 1);
    expect(
      find.byKey(const Key('system-test-clear-confirm-dialog')),
      findsOneWidget,
    );
  });

  testWidgets('清空请求超时：提示可能仍在后台执行，弹窗保持打开且不登出', (tester) async {
    final repository = _FakeRepository(error: NetworkTimeoutException());
    final notifier = _TestSessionNotifier();
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: notifier,
    );
    await _expandAndOpenDialog(tester);
    await _typePhraseAndSubmit(tester);

    expect(repository.calls, 1);
    expect(notifier.logouts, 0);
    expect(
      find.byKey(const Key('system-test-clear-confirm-dialog')),
      findsOneWidget,
    );
    final hint = find.byKey(const Key('system-test-clear-timeout-hint'));
    expect(hint, findsOneWidget);
    expect(tester.widget<Text>(hint).data, contains('清空可能仍在后台执行'));
    // 超时后可重试提交（按钮恢复可点）
    await tester.tap(find.byKey(const Key('system-test-clear-confirm-submit')));
    await tester.pumpAndSettle();
    expect(repository.calls, 2);
  });

  testWidgets('清空成功：登出并跳登录页', (tester) async {
    final repository = _FakeRepository(result: _okResult);
    final notifier = _TestSessionNotifier();
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: notifier,
    );
    await _expandAndOpenDialog(tester);
    await _typePhraseAndSubmit(tester);

    expect(repository.calls, 1);
    expect(notifier.logouts, 1);
    expect(find.text('登录页'), findsOneWidget);
  });
}
