// 工作台「系统测试」区 widget 测试：
// · 非超管不渲染；超管可见（默认收起，展开后见卡片与按钮）
// · 确认弹窗口令门禁：逐字输入「清空业务数据」才可提交
// · 清空前检查(与服务端清空时同一个检查)：有测试文件显示计数仍可清空；有拒绝原因逐条显示
//   服务端原文并禁用，「重新检查」没有原因后放行；核对不完、全部不在只提醒不禁用；
//   预览失败(非 FORBIDDEN)仍可提交；预览 FORBIDDEN / 服务器配置有误显示后端原话并保持禁用；
//   服务端没有核对存储时不显示「只核对了 c / n 个」，也不报 0 个还在存储里
// · 失败路径：弹窗保持打开、原文留在弹窗里并自动重新检查(含带说明的 500，例如删了部分文件后
//   数据库失败)；结果说不清的路径(超时、网关错误页、服务端明说未确认)：提示「可能仍在后台执行」、不登出
// · 成功路径：弹窗关闭、调用仓库一次、本地登出并跳登录页
// · 展开后回显上次清空结果(重登后可见)；上次失败且已删部分文件时写明已删数
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/dashboard/repositories/system_test_repository.dart';
import 'package:uten_imp/features/dashboard/models/business_data_reset_attempt.dart';
import 'package:uten_imp/features/dashboard/widgets/system_test_area.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_epoch_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

class _FakeRepository implements SystemTestRepository {
  _FakeRepository({this.result, this.error});

  final BusinessDataResetResult? result;

  /// NetworkTimeoutException 也是 ApiException 子类，可直接放这里。
  ApiException? error;
  int calls = 0;
  int previewCalls = 0;
  BusinessDataResetPreview preview = const BusinessDataResetPreview();
  ApiException? previewError;
  BusinessDataResetLastResult lastResult = BusinessDataResetLastResult.none;
  ApiException? lastResultError;
  int lastResultCalls = 0;
  BusinessDataResetAttempt? pending;

  @override
  Future<BusinessDataResetPreview> previewBusinessDataReset() async {
    previewCalls++;
    if (previewError != null) throw previewError!;
    return preview;
  }

  @override
  Future<BusinessDataResetResult> resetBusinessData() async {
    calls++;
    if (error != null) {
      if (isBusinessDataResetOutcomeUncertain(error!)) {
        pending ??= BusinessDataResetAttempt(
          id: 'attempt-1',
          server: 'https://test/api',
          operatorId: 'operator-1',
          startedAt: DateTime.utc(2026, 9, 12),
        );
      }
      throw error!;
    }
    return result!;
  }

  @override
  Future<BusinessDataResetLastResult> lastBusinessDataResetResult() async {
    lastResultCalls++;
    if (lastResultError != null) throw lastResultError!;
    // 真仓库在精确完成回执或按服务端受理回执确定撤销时都会删掉本地记录。
    if (lastResult.confirmedPendingAttempt ||
        lastResult.retiredPendingReason != null) {
      pending = null;
    }
    return lastResult;
  }

  @override
  Future<BusinessDataResetAttempt?> pendingBusinessDataReset() async => pending;
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
  deadBackgroundEventsCleared: 2,
);

/// 有测试文件、没有拒绝原因：业务附件 2 份 + AI识别原件 1 份，共 4 个存储位置。
const _filesPreview = BusinessDataResetPreview(
  locations: 4,
  presentFiles: 3,
  absentFiles: 1,
  inspectedObjects: 4,
  kinds: [
    BusinessDataResetFileKind(label: '业务附件', files: 2),
    BusinessDataResetFileKind(label: '上传会话', files: 0),
    BusinessDataResetFileKind(label: 'AI识别原件', files: 1),
  ],
);

const _outboxRefusal =
    '后台还有 3 条事件正在排队处理(消息通知、单据联动等)，预计 3 分钟内处理完。'
    '现在清空会丢掉这些处理结果，请 3 分钟后点「重新检查」再清空。';
const _versionRefusal =
    '以下测试文件现在无法确认或无法删除，本次没有删除任何文件，也没有清空数据：\n'
    '1 个文件在存储里的内容和登记的不是同一份(文件被替换过)，系统不会删除它们：'
    '「合同原件.pdf」(业务附件, 正式文件)。需要开发人员核对哪一份是对的并处理，然后点「重新检查」。';

const _refusedPreview = BusinessDataResetPreview(
  locations: 4,
  presentFiles: 3,
  absentFiles: 1,
  inspectedObjects: 4,
  kinds: [BusinessDataResetFileKind(label: '业务附件', files: 4)],
  refusals: [
    BusinessDataResetRefusal(
      code: 'BACKGROUND_EVENTS_PENDING',
      count: 3,
      message: _outboxRefusal,
    ),
    BusinessDataResetRefusal(
      code: 'VERSION_MISMATCH',
      count: 1,
      message: _versionRefusal,
    ),
  ],
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
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
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

Future<void> _typePhrase(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('system-test-clear-confirm-input')),
    '清空业务数据',
  );
  await tester.pump();
}

Future<void> _typePhraseAndSubmit(WidgetTester tester) async {
  await _typePhrase(tester);
  await tester.tap(find.byKey(const Key('system-test-clear-confirm-submit')));
  await tester.pumpAndSettle();
}

String _textOf(WidgetTester tester, Key key) =>
    tester.widget<Text>(find.byKey(key)).data!;

void main() {
  testWidgets('有测试文件：显示按类别的份数与实地核对结果，确认按钮可点，清空请求发出一次', (tester) async {
    final repository = _FakeRepository(result: _okResult)
      ..preview = _filesPreview;
    final notifier = _TestSessionNotifier();
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: notifier,
    );
    await _expandAndOpenDialog(tester);
    expect(repository.previewCalls, 1);
    expect(
      _textOf(tester, const Key('system-test-reset-preview-files')),
      '将一并物理删除测试文件：业务附件 2 份、AI识别原件 1 份'
      '(共 4 个存储位置：3 个文件还在存储里，将被删除；1 个已经不在)。'
      '人事档案/合同、货品图片/图纸、成本导入原件和已采用的报价模板不会删除。',
    );
    expect(find.byKey(const Key('system-test-reset-refusals')), findsNothing);
    expect(
      find.byKey(const Key('system-test-reset-preview-partial')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('system-test-reset-all-missing')),
      findsNothing,
    );
    // 「先分批清理」入口已删除：清空是唯一入口。
    expect(find.textContaining('分批清理'), findsNothing);
    await _typePhraseAndSubmit(tester);
    expect(repository.calls, 1);
    expect(notifier.logouts, 1);
    expect(find.text('登录页'), findsOneWidget);
  });

  testWidgets('没有测试文件：明确写出没有需要删除的文件', (tester) async {
    final repository = _FakeRepository(result: _okResult);
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: _TestSessionNotifier(),
    );
    await _expandAndOpenDialog(tester);
    expect(
      _textOf(tester, const Key('system-test-reset-preview-none')),
      '没有需要删除的测试文件。',
    );
    expect(
      find.byKey(const Key('system-test-reset-preview-files')),
      findsNothing,
    );
  });

  testWidgets('有拒绝原因：逐条显示服务端原文并禁用；重新检查没有原因后放行', (tester) async {
    final repository = _FakeRepository(result: _okResult)
      ..preview = _refusedPreview;
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: _TestSessionNotifier(),
    );
    await _expandAndOpenDialog(tester);
    final refusals = find.byKey(const Key('system-test-reset-refusals'));
    expect(refusals, findsOneWidget);
    expect(
      find.descendant(of: refusals, matching: find.text('现在不能清空，原因如下：')),
      findsOneWidget,
    );
    // 每条原因都是服务端原文，逐字显示(含文件名、来源类别和下一步)。
    for (final message in [_outboxRefusal, _versionRefusal]) {
      expect(
        find.descendant(of: refusals, matching: find.text(message)),
        findsOneWidget,
      );
    }
    // 文件计数照样显示，用户一次看清全部情况。
    expect(
      find.byKey(const Key('system-test-reset-preview-files')),
      findsOneWidget,
    );
    await _typePhraseAndSubmit(tester);
    expect(repository.calls, 0, reason: '有拒绝原因时确认按钮禁用');
    expect(
      find.byKey(const Key('system-test-clear-confirm-dialog')),
      findsOneWidget,
    );

    repository.preview = _filesPreview;
    await tester.tap(find.byKey(const Key('system-test-reset-recheck')));
    await tester.pumpAndSettle();
    expect(repository.previewCalls, 2);
    expect(find.byKey(const Key('system-test-reset-refusals')), findsNothing);
    await tester.tap(find.byKey(const Key('system-test-clear-confirm-submit')));
    await tester.pumpAndSettle();
    expect(repository.calls, 1);
  });

  testWidgets('文件太多预先没核对完：提示其余在清空时核对，仍可提交', (tester) async {
    final repository = _FakeRepository(result: _okResult)
      ..preview = const BusinessDataResetPreview(
        locations: 5000,
        presentFiles: 1200,
        inspectedObjects: 1200,
        inspectionComplete: false,
        kinds: [BusinessDataResetFileKind(label: '业务附件', files: 5000)],
      );
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: _TestSessionNotifier(),
    );
    await _expandAndOpenDialog(tester);
    expect(
      _textOf(tester, const Key('system-test-reset-preview-partial')),
      '文件较多，预先只核对了 1200 / 5000 个；'
      '其余会在清空时核对，有问题会在删除任何文件之前停下并说明原因。',
    );
    await _typePhraseAndSubmit(tester);
    expect(repository.calls, 1);
  });

  testWidgets('登记的文件一个都没找到：醒目提醒存储盘，但不禁用', (tester) async {
    final repository = _FakeRepository(result: _okResult)
      ..preview = const BusinessDataResetPreview(
        locations: 3,
        absentFiles: 3,
        inspectedObjects: 3,
        allListedMissing: true,
        kinds: [BusinessDataResetFileKind(label: '业务附件', files: 3)],
      );
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: _TestSessionNotifier(),
    );
    await _expandAndOpenDialog(tester);
    final notice = find.byKey(const Key('system-test-reset-all-missing'));
    expect(notice, findsOneWidget);
    expect(
      find.descendant(
        of: notice,
        matching: find.text(
          '登记的 3 个测试文件在存储里一个都没找到。'
          '如果服务器的附件存储盘没有挂载好，请先让维护人员检查；'
          '否则清空后这些文件会留在存储盘里，以后只能靠附件对账找出来。',
        ),
      ),
      findsOneWidget,
    );
    await _typePhraseAndSubmit(tester);
    expect(repository.calls, 1);
  });

  testWidgets('失败后停止重试的后台事件：按类别报条数，含单重重算时说明夜间补算', (tester) async {
    final repository = _FakeRepository(result: _okResult)
      ..preview = const BusinessDataResetPreview(
        deadBackgroundEvents: [
          BusinessDataResetDeadEvents(label: '货品单重重算', events: 2),
          BusinessDataResetDeadEvents(label: '销售相关', events: 1),
        ],
      );
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: _TestSessionNotifier(),
    );
    await _expandAndOpenDialog(tester);
    expect(
      _textOf(tester, const Key('system-test-reset-dead-events')),
      '另有 3 条处理失败、已停止重试的后台事件会一并清除(货品单重重算 2 条、销售相关 1 条)。'
      '货品单重估算如果因此没有更新，每晚 2 点 13 分会自动补算。',
    );
    await _typePhraseAndSubmit(tester);
    expect(repository.calls, 1);
  });

  testWidgets('预览失败(非 FORBIDDEN)：带原话说明清空时会再核对，仍可提交', (tester) async {
    final repository = _FakeRepository(result: _okResult)
      ..previewError = ApiException('INTERNAL', '服务器繁忙，请稍后再试');
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: _TestSessionNotifier(),
    );
    await _expandAndOpenDialog(tester);
    expect(
      _textOf(tester, const Key('system-test-reset-preview-error')),
      '无法预先核对测试文件(服务器繁忙，请稍后再试)。清空时服务器会再次核对，仍可提交。',
    );
    await _typePhraseAndSubmit(tester);
    expect(repository.calls, 1);
    expect(
      find.byKey(const Key('system-test-clear-confirm-dialog')),
      findsNothing,
    );
  });

  testWidgets('预览 FORBIDDEN(运行开关未开启)：显示后端原话并保持禁用', (tester) async {
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
    expect(find.textContaining('仍可提交'), findsNothing);
    await _typePhraseAndSubmit(tester);
    expect(repository.calls, 0);
    expect(
      find.byKey(const Key('system-test-clear-confirm-dialog')),
      findsOneWidget,
    );
    // 「重新检查」可重试：开关打开后预览成功即放行
    repository.previewError = null;
    await tester.tap(find.byKey(const Key('system-test-reset-recheck')));
    await tester.pumpAndSettle();
    expect(repository.previewCalls, 2);
    await _typePhraseAndSubmit(tester);
    expect(repository.calls, 1);
  });

  testWidgets('预览说服务器配置有误：显示后端原话并保持禁用，不说「仍可提交」', (tester) async {
    const backendMessage =
        '服务器上清空程序的数据库账号配置有误，本次没有删除任何文件，也没有清空数据。'
        '请联系开发人员处理后点「重新检查」。';
    final repository = _FakeRepository(result: _okResult)
      ..previewError = ApiException(
        'RESET_SERVER_MISCONFIGURED',
        backendMessage,
        httpStatus: 500,
        hasResponseCode: true,
      );
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: _TestSessionNotifier(),
    );
    await _expandAndOpenDialog(tester);
    expect(
      _textOf(tester, const Key('system-test-reset-preview-error')),
      backendMessage,
    );
    expect(find.textContaining('仍可提交'), findsNothing);
    await _typePhraseAndSubmit(tester);
    expect(repository.calls, 0, reason: '服务器配置有误时清空注定失败，确认按钮禁用');
    expect(
      find.byKey(const Key('system-test-clear-confirm-dialog')),
      findsOneWidget,
    );
  });

  testWidgets('服务端没有核对存储：不显示「只核对了」，也不报 0 个还在存储里', (tester) async {
    const catalogRefusal =
        '清空分类有问题：有 1 张新数据表没有归入清除或保留(程序版本问题)。'
        '本次没有删除任何文件，也没有清空数据。请联系开发人员。';
    final repository = _FakeRepository(result: _okResult)
      ..preview = const BusinessDataResetPreview(
        locations: 4,
        inspectionComplete: false,
        inspectionSkipped: true,
        kinds: [BusinessDataResetFileKind(label: '业务附件', files: 4)],
        refusals: [
          BusinessDataResetRefusal(
            code: 'CATALOG_UNCLASSIFIED',
            count: 1,
            message: catalogRefusal,
          ),
        ],
      );
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: _TestSessionNotifier(),
    );
    await _expandAndOpenDialog(tester);
    expect(find.text(catalogRefusal), findsOneWidget);
    expect(
      find.byKey(const Key('system-test-reset-preview-partial')),
      findsNothing,
    );
    expect(find.textContaining('预先只核对了'), findsNothing);
    expect(
      _textOf(tester, const Key('system-test-reset-preview-files')),
      '将一并物理删除测试文件：业务附件 4 份'
      '(共 4 个存储位置；这次没有核对它们是否还在存储里，先处理上面的问题，再点「重新检查」核对)。'
      '人事档案/合同、货品图片/图纸、成本导入原件和已采用的报价模板不会删除。',
    );
    await _typePhraseAndSubmit(tester);
    expect(repository.calls, 0);
  });

  testWidgets('清空被明确拒绝(409)：原文留在弹窗里，自动重新检查并显示拒绝原因', (tester) async {
    const failure =
        '本次已经物理删除了 2 个测试文件(无法恢复)，但业务数据没有清空，所以这些测试单据上的附件现在打不开。'
        '原因：「报价单.xlsx」(业务附件, 正式文件)删除后再次核对，仍然在存储里。'
        '请让维护人员检查服务器存储后重新点「确认清空」。已删除的文件下次不会重复处理。';
    final repository = _FakeRepository(
      error: ApiException('CONFLICT', failure, httpStatus: 409),
    )..preview = _filesPreview;
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: _TestSessionNotifier(),
    );
    await _expandAndOpenDialog(tester);
    expect(repository.previewCalls, 1);
    repository.preview = _refusedPreview;
    await _typePhraseAndSubmit(tester);

    expect(repository.calls, 1);
    expect(
      find.byKey(const Key('system-test-clear-confirm-dialog')),
      findsOneWidget,
    );
    final submitError = find.byKey(const Key('system-test-reset-submit-error'));
    expect(submitError, findsOneWidget);
    expect(
      find.descendant(of: submitError, matching: find.text(failure)),
      findsOneWidget,
    );
    // 失败后按同一个检查自动刷新：新出现的拒绝原因逐条显示，确认按钮随之禁用。
    expect(repository.previewCalls, 2);
    expect(find.text(_outboxRefusal), findsOneWidget);
    await tester.tap(find.byKey(const Key('system-test-clear-confirm-submit')));
    await tester.pumpAndSettle();
    expect(repository.calls, 1);
  });

  testWidgets('删了部分文件后数据库失败(500 带说明)：原文照登，不当成待确认，可再次提交', (tester) async {
    const failure =
        '本次已经物理删除了 2 个测试文件(无法恢复)，但业务数据没有清空，所以这些测试单据上的附件现在打不开。'
        '原因：业务数据清空执行失败，已整体回滚：磁盘空间不足。请重新点「确认清空」；如果再次出现，请联系开发人员。'
        '已删除的文件下次不会重复处理。';
    final repository = _FakeRepository(
      error: ApiException(
        'INTERNAL',
        failure,
        httpStatus: 500,
        hasResponseCode: true,
      ),
    )..preview = _filesPreview;
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
    expect(repository.pending, isNull, reason: '确定的失败不留待确认记录');
    expect(notifier.logouts, 0);
    final submitError = find.byKey(const Key('system-test-reset-submit-error'));
    expect(submitError, findsOneWidget);
    expect(
      find.descendant(of: submitError, matching: find.text(failure)),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('system-test-clear-timeout-hint')),
      findsNothing,
    );
    expect(find.textContaining('结果待确认'), findsNothing);
    // 失败后自动重新检查；没有新的拒绝原因时，用户可以明确地再点一次。
    expect(repository.previewCalls, 2);
    await tester.tap(find.byKey(const Key('system-test-clear-confirm-submit')));
    await tester.pumpAndSettle();
    expect(repository.calls, 2);
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
        deadBackgroundEventsCleared: 2,
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
    expect(text, contains('清空 266 张业务表(12 行)'));
    expect(text, endsWith('物理删除测试文件 3 个，清除失败的后台事件 2 条'));
  });

  testWidgets('上次清空失败且已删部分文件：写明已删数与数据没有清空，可以重新提交', (tester) async {
    const failed = BusinessDataResetLastResult(
      available: false,
      receiptsSupported: true,
      attemptReceived: true,
      attemptReceivedByCurrentServer: true,
      attemptFailed: true,
      attemptFailureMessage: '失败原因：删除文件失败。完整原因(含文件名)请在清空弹窗点「重新检查」查看。',
      attemptDeletedAttachmentFiles: 2,
    );
    final repository = _FakeRepository()
      ..pending = BusinessDataResetAttempt(
        id: 'attempt-1',
        server: 'https://test/api',
        operatorId: 'operator-1',
        startedAt: DateTime.utc(2026, 9, 12),
      )
      ..lastResult = failed.retiredPendingAttempt(
        businessDataResetFailureNotice(failed),
      );
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: _TestSessionNotifier(),
    );
    await tester.tap(find.text('系统测试'));
    await tester.pumpAndSettle();
    final notice = find.byKey(const Key('system-test-reset-retired-notice'));
    expect(notice, findsOneWidget);
    expect(
      tester.widget<Text>(notice).data,
      '上次清空没有完成：失败原因：删除文件失败。完整原因(含文件名)请在清空弹窗点「重新检查」查看。'
      '(已物理删除 2 个测试文件，数据没有清空)。本地待确认记录已撤销，现在可以重新提交清空。',
    );
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
    expect(
      find.byKey(const Key('system-test-reset-submit-error')),
      findsNothing,
    );
    // Unknown outcome must never submit another destructive request.
    await tester.tap(find.byKey(const Key('system-test-clear-confirm-submit')));
    await tester.pumpAndSettle();
    expect(repository.calls, 1);
  });

  // 说不清服务端有没有执行完的失败：网关错误页(没有统一错误码的 5xx)、本端登录状态切换、
  // 服务端明说结果未确认。
  for (final error in [
    ApiException('INTERNAL', '服务器繁忙，请稍后再试', httpStatus: 500),
    ApiException('INTERNAL', '服务器繁忙，请稍后再试', httpStatus: 503),
    ApiException('INTERNAL', '服务器繁忙，请稍后再试', httpStatus: 504),
    ApiException('INTERNAL', '服务器繁忙，请稍后再试', httpStatus: 502),
    NetworkException(),
    ApiException(
      'SESSION_CHANGED',
      '登录状态已切换，本次旧请求结果已忽略',
      httpStatus: 409,
      hasResponseCode: true,
    ),
    ApiException(
      'RESET_OUTCOME_UNCERTAIN',
      '业务数据清空未确认完成，请重新登录核对本次结果(事务提交或完成回执写入失败)',
      httpStatus: 500,
      hasResponseCode: true,
    ),
  ]) {
    testWidgets('${error.code}/${error.httpStatus}待确认且重建页面也不重复提交', (
      tester,
    ) async {
      final repository = _FakeRepository(error: error);
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
        find.byKey(const Key('system-test-clear-timeout-hint')),
        findsOneWidget,
      );
      expect(find.text('清空失败'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await _pump(
        tester,
        superAdmin: true,
        repository: repository,
        notifier: _TestSessionNotifier(),
      );
      await _expandAndOpenDialog(tester);
      await _typePhraseAndSubmit(tester);
      expect(repository.calls, 1);
    });
  }

  testWidgets('完成记录读取失败可见并可重试，不发清空请求', (tester) async {
    final repository = _FakeRepository()
      ..lastResultError = NetworkTimeoutException();
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: _TestSessionNotifier(),
    );
    expect(find.textContaining('无法读取清空完成记录'), findsOneWidget);
    repository.lastResultError = null;
    await tester.tap(find.byKey(const Key('system-test-last-reset-retry')));
    await tester.pumpAndSettle();
    expect(repository.lastResultCalls, 2);
    expect(repository.calls, 0);
  });

  testWidgets('登录纪元变化重新核对并显示本次精确完成回执', (tester) async {
    final repository = _FakeRepository()
      ..pending = BusinessDataResetAttempt(
        id: 'attempt-1',
        server: 'https://test/api',
        operatorId: 'operator-1',
        startedAt: DateTime.utc(2026, 9, 12),
      );
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: _TestSessionNotifier(),
    );
    expect(repository.lastResultCalls, 1);
    repository.lastResult = BusinessDataResetLastResult(
      available: true,
      finishedAt: DateTime.utc(2026, 9, 12, 0, 2),
      operatorAccount: 'admin',
      operatorId: 'operator-1',
      attemptId: 'attempt-1',
      clearedTableCount: 269,
      clearedRows: 697,
      preservedTableCount: 96,
      authorizationEpochAfter: 366,
      confirmedPendingAttempt: true,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SystemTestArea)),
    );
    container.read(sessionEpochProvider.notifier).state++;
    await tester.pumpAndSettle();
    expect(repository.lastResultCalls, 2);
    expect(find.textContaining('本次清空已确认'), findsOneWidget);
    expect(repository.calls, 0);
  });

  // ADR-067 §9：服务器从未收到的清空请求（提交时连接中断）不能把按钮永久锁死——服务端
  // 受理回执说「没收到」，本地待确认记录撤销、明确提示可以重新提交，弹窗内不必重开。
  testWidgets('服务器未受理的待确认记录按回执撤销并恢复提交', (tester) async {
    final repository =
        _FakeRepository(result: _okResult, error: NetworkException())
          ..lastResult = BusinessDataResetLastResult.none.retiredPendingAttempt(
            '服务器没有收到本次清空请求（提交时连接中断），没有执行清空',
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
    // 提交失败 → 弹窗进入等待态 → 核对结果时服务端回执判定「未收到」→ 撤销并提示。
    await tester.pumpAndSettle();
    // 结果行在弹窗内与系统测试区各渲染一份，两处都要说清已撤销。
    expect(
      find.byKey(const Key('system-test-reset-retired-notice')),
      findsWidgets,
    );
    expect(find.textContaining('现在可以重新提交清空'), findsWidgets);
    expect(find.text('尚未查到本次清空的完成记录，可能仍在执行。请稍后核对，不要再次提交。'), findsNothing);
    // 记录已撤销：口令仍在，确认按钮重新可点，再次提交真的会发第二次请求。
    repository.error = null;
    await tester.tap(find.byKey(const Key('system-test-clear-confirm-submit')));
    await tester.pumpAndSettle();
    expect(repository.calls, 2);
  });

  testWidgets('清空成功：提示删除的测试文件与清除的失败事件，登出并跳登录页', (tester) async {
    final repository = _FakeRepository(result: _okResult);
    final notifier = _TestSessionNotifier();
    await _pump(
      tester,
      superAdmin: true,
      repository: repository,
      notifier: notifier,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SystemTestArea)),
    );
    await _expandAndOpenDialog(tester);
    await _typePhraseAndSubmit(tester);

    expect(repository.calls, 1);
    expect(notifier.logouts, 1);
    expect(find.text('登录页'), findsOneWidget);
    expect(
      container.read(appNotificationProvider).map((item) => item.message),
      contains(
        '已清空 222 张业务表(5 行)，保留 96 张主档，'
        '物理删除测试文件 3 个，清除失败的后台事件 2 条；请重新登录',
      ),
    );
  });
}
