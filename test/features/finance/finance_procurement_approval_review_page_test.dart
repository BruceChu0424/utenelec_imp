// 订货审批审核详情页（财务专用视图）测试：
//  - 卡片结构（状态条/供应商快照/订单信息/明细/审批历史）与底部三操作；
//  - 2026-10-10 财务订货审批口径：独立 tableKey、新默认列序（数量单位内联、
//    换算率/单位列退役）、汇率编辑器默认值/编辑联动/提交体、供应商红色加粗、
//    highlightColumnKeys（采购超收%/委外损耗%）、折合人民币实时重算；
//  - 通过：选填备注 + 汇率随单笔 batch-approve 提交，成功后 pop(true) 回列表；
//  - 驳回：原因必填，空原因内联报错；
//  - 非 PENDING / 无动作 case 不渲染底栏（服务端 allowedActions 为准）。
import 'package:flutter/material.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/data_display/uten_revision_table.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_workflow.dart';
import 'package:uten_imp/features/finance/pages/finance_procurement_approval_review_page.dart';
import 'package:uten_imp/features/finance/repositories/finance_procurement_workflow_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/repositories/task_claim_repository.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import '../../helpers/finance_claim_fixture.dart';

import '../../helpers/badge_summary_fixture.dart';

class _FakeWorkflowRepo implements FinanceProcurementWorkflowRepository {
  @override
  Future<List<MasterFacetBucket>> approvalBillNoFacets({
    FinanceProcurementOrderType? orderType,
    String? keyword,
  }) async => const []; // 2026-09-25 单号列统一：页面 facets 静默降级。
  _FakeWorkflowRepo(this.reviewResult);

  FinanceProcurementApprovalReview reviewResult;
  String? requestedCaseId;
  final List<
    ({List<FinanceProcurementDecisionItem> items, String? remark, double? exchangeRate})
  >
  approved = [];
  final List<({List<FinanceProcurementDecisionItem> items, String reason})>
  rejected = [];

  @override
  Future<FinanceProcurementApprovalPage> approvalTasks({
    int page = 1,
    int size = 20,
    FinanceProcurementOrderType? orderType,
    String? keyword,
    String? sort,
    String? order,
    String? billNo,
  }) async => const FinanceProcurementApprovalPage(
    items: [],
    page: 1,
    size: 20,
    total: 0,
    totalPages: 1,
  );

  @override
  Future<Map<String, int>> approvalTypeCounts() async => {'PURCHASE': 1};

  @override
  Future<FinanceProcurementApprovalReview> review(String caseId) async {
    requestedCaseId = caseId;
    return reviewResult;
  }

  @override
  Future<void> approveOrdersBatch(
    List<FinanceProcurementDecisionItem> items, {
    String? remark,
    double? exchangeRate,
  }) async {
    approved.add((
      items: List.of(items),
      remark: remark,
      exchangeRate: exchangeRate,
    ));
  }

  @override
  Future<void> rejectOrdersBatch(
    List<FinanceProcurementDecisionItem> items,
    String reason,
  ) async {
    rejected.add((items: List.of(items), reason: reason));
  }
}

class _FinanceReviewerSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    user: AppUser(id: 'finance-reviewer', code: 'FIN001', name: '财务李四'),
  );
}

Map<String, dynamic> _pendingReviewJson({
  String status = 'PENDING',
  Set<String> allowedActions = const {'APPROVE', 'REJECT'},
}) => {
  'caseId': 'case-1',
  'orderId': 'order-1',
  'orderType': 'PURCHASE',
  'billNo': 'PO-2026-001',
  'status': status,
  'attempt': 2,
  'version': 3,
  'allowedActions': allowedActions.toList(),
  'submittedByName': '张三',
  'submittedAt': '2026-09-02T02:00:00+08:00',
  'billDate': '2026-09-01',
  'supplierName': '供应商A',
  'supplierCode': 'S-001',
  'warehouseName': '一号仓',
  'currencyName': '美元',
  'exchangeRate': '7.1',
  'settlementMethodName': '月结30天',
  'taxRate': '13',
  'purchaserName': '采购员甲',
  'makerName': '制单员乙',
  'deliverDate': '2026-09-15',
  'remark': '加急',
  'totalOriginal': '10000',
  'totalLocal': '71000',
  // ADR-128：供应商应付按本单币种(美元)显示，其它币种另列、不换算。
  'supplierBalance': {
    'currencyName': '美元',
    'openOriginal': '13000.50',
    'creditOriginal': '500',
    'netOriginal': '12500.50',
    'baseCurrencyName': '人民币',
    'otherCurrencies': [
      {'currencyName': '人民币', 'openOriginal': '1100', 'netOriginal': '1100'},
    ],
  },
  'sourceApplicationCount': 2,
  'items': [
    {
      'orderItemId': 'order-item-1',
      'displaySnapshotComplete': true,
      'lineNo': 1,
      'goodsCode': 'G001',
      'goodsName': '铜线',
      'colorName': '裸色',
      'unitName': '公斤',
      'unitRate': '1',
      'qty': '100',
      'price': '100',
      'amountOriginal': '10000',
      'amountLocal': '71000',
      'deliverDate': '2026-09-15',
      'sourceDocNo': 'PR-2026-010',
    },
  ],
  'history': [
    {
      'attempt': 1,
      'eventType': 'SUBMITTED',
      'actorName': '张三',
      'occurredAt': '2026-09-01T01:00:00+08:00',
    },
    {
      'attempt': 1,
      'eventType': 'REJECTED',
      'actorName': '财务王五',
      'occurredAt': '2026-09-01T05:00:00+08:00',
      'reason': '单价待复核',
    },
    {
      'attempt': 2,
      'eventType': 'SUBMITTED',
      'actorName': '张三',
      'occurredAt': '2026-09-02T02:00:00+08:00',
    },
  ],
};

FinanceProcurementApprovalReview _pendingReview({
  String status = 'PENDING',
  Set<String> allowedActions = const {'APPROVE', 'REJECT'},
}) => FinanceProcurementApprovalReview.fromJson(
  _pendingReviewJson(status: status, allowedActions: allowedActions),
);

Future<GoRouter> _pumpReviewPage(
  WidgetTester tester,
  _FakeWorkflowRepo repository, {
  bool withApprovePerms = true,
  FinanceClaimFixture? claims,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = GoRouter(
    initialLocation: '/finance/procurement-approvals/case-1',
    routes: [
      GoRoute(
        path: '/finance/procurement-approvals/:caseId',
        builder: (_, state) => FinanceProcurementApprovalReviewPage(
          caseId: state.pathParameters['caseId']!,
        ),
      ),
      GoRoute(
        path: '/finance/procurement-approvals',
        builder: (_, _) => const Scaffold(body: Text('任务中心列表')),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        isSuperAdminProvider.overrideWithValue(false),
        currentPermissionsProvider.overrideWithValue({
          Perm.financeOrderApprovalView,
          if (withApprovePerms) ...{
            Perm.financeOrderApprovalApprove,
            Perm.financeOrderApprovalReject,
          },
        }),
        sessionProvider.overrideWith(_FinanceReviewerSessionNotifier.new),
        taskClaimRepositoryProvider.overrideWithValue(
          claims ?? FinanceClaimFixture(),
        ),
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(facts: {BadgeFact.procurementApproval: 1}),
        ),
        financeProcurementWorkflowRepositoryProvider.overrideWithValue(
          repository,
        ),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  for (final type in ['PURCHASE', 'SUBCONTRACT']) {
    testWidgets('$type 总金额计价在财审中标记参考单价并保持金额原文', (tester) async {
      final json = _pendingReviewJson();
      final original = Map<String, dynamic>.from(
        (json['items'] as List).single as Map,
      );
      final review = FinanceProcurementApprovalReview.fromJson({
        ...json,
        'orderType': type,
        'items': [
          {
            ...original,
            'qty': '3000',
            'price': '0.0333333333',
            'totalAmountInput': '100.000000000000000001',
            'amountOriginal': '100.000000000000000001',
          },
        ],
      });
      await _pumpReviewPage(tester, _FakeWorkflowRepo(review));
      final finder = find.byKey(
        const Key('procurement-approval-revision-table'),
      );
      await tester.scrollUntilVisible(
        finder,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      final table = tester
          .widget<UtenRevisionTable<FinanceProcurementReviewLine>>(finder);
      final row = table.rows.single.value;
      expect(
        table.columns.singleWhere((column) => column.key == 'price').value(row),
        '0.0333333333 美元（参考）',
      );
      expect(
        table.columns
            .singleWhere((column) => column.key == 'amountOriginal')
            .value(row),
        '100.000000000000000001 美元',
      );
    });
  }

  testWidgets('loss allowance only and cleared header remark remain visible', (
    tester,
  ) async {
    final json = _pendingReviewJson();
    final original = Map<String, dynamic>.from(
      (json['items'] as List).single as Map,
    );
    final review = FinanceProcurementApprovalReview.fromJson({
      ...json,
      'orderType': 'SUBCONTRACT',
      'remark': null,
      'previousHeaderSnapshot': {'remark': '原审批备注'},
      'headerSnapshot': {'remark': null},
      'previousItems': [
        {...original, 'allowedLossPct': '2.50'},
      ],
      'items': [
        {...original, 'allowedLossPct': '3.75'},
      ],
    });
    await _pumpReviewPage(tester, _FakeWorkflowRepo(review));
    final finder = find.byKey(const Key('procurement-approval-revision-table'));
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    final table = tester
        .widget<UtenRevisionTable<FinanceProcurementReviewLine>>(finder);
    expect(table.rows.last.changedKeys, {'allowedLossPct'});
    final column = table.columns.singleWhere(
      (column) => column.key == 'allowedLossPct',
    );
    expect(table.rows.map((row) => column.value(row.value)), ['2.5%', '3.75%']);
    expect(find.text('明细对比 · 修改 1 行 · 删除 0 行 · 新增 0 行'), findsOneWidget);
    expect(find.text('原审批备注'), findsOneWidget);
    expect(find.text('未填写'), findsOneWidget);
  });

  testWidgets('ADR-144 采购允许超收%：列只在采购显示，改比例标记修改，历史快照也能比', (tester) async {
    final json = _pendingReviewJson();
    final original = Map<String, dynamic>.from(
      (json['items'] as List).single as Map,
    );
    final review = FinanceProcurementApprovalReview.fromJson({
      ...json,
      'orderType': 'PURCHASE',
      'previousItems': [
        // 旧提交快照：展示快照不完整，但允许超收在审批哈希快照里，照样能比。
        {...original, 'displaySnapshotComplete': false},
      ],
      'items': [
        {...original, 'allowedOverReceiptPct': '5.00'},
      ],
    });
    await _pumpReviewPage(tester, _FakeWorkflowRepo(review));
    final finder = find.byKey(const Key('procurement-approval-revision-table'));
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    final table = tester
        .widget<UtenRevisionTable<FinanceProcurementReviewLine>>(finder);
    final column = table.columns.singleWhere(
      (column) => column.key == 'allowedOverReceiptPct',
    );
    expect(column.label, '允许超收');
    expect(table.rows.map((row) => column.value(row.value)), ['不允许', '5%']);
    expect(table.rows.last.changedKeys, contains('allowedOverReceiptPct'));
    expect(
      table.columns.where((column) => column.key == 'allowedLossPct'),
      isEmpty,
      reason: '采购不显示委外允许损耗列',
    );
  });

  testWidgets('ADR-144 委外订货不显示允许超收列', (tester) async {
    final review = FinanceProcurementApprovalReview.fromJson({
      ..._pendingReviewJson(),
      'orderType': 'SUBCONTRACT',
    });
    await _pumpReviewPage(tester, _FakeWorkflowRepo(review));
    final finder = find.byKey(const Key('procurement-approval-revision-table'));
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    final table = tester
        .widget<UtenRevisionTable<FinanceProcurementReviewLine>>(finder);
    expect(
      table.columns.where((column) => column.key == 'allowedOverReceiptPct'),
      isEmpty,
    );
  });

  testWidgets(
    'unknown old fields are counted for checking rather than claimed edits',
    (tester) async {
      final json = _pendingReviewJson();
      final original = Map<String, dynamic>.from(
        (json['items'] as List).single as Map,
      );
      final review = FinanceProcurementApprovalReview.fromJson({
        ...json,
        'previousHeaderSnapshot': {'billDate': '2026-09-23'},
        'headerSnapshot': {'billDate': '2026-09-23', 'remark': '新记录'},
        'previousItems': [
          {...original, 'displaySnapshotComplete': false},
        ],
        'items': [
          {...original, 'remark': '新记录'},
        ],
      });
      await _pumpReviewPage(tester, _FakeWorkflowRepo(review));
      final finder = find.byKey(
        const Key('procurement-approval-revision-table'),
      );
      await tester.scrollUntilVisible(
        finder,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      final table = tester
          .widget<UtenRevisionTable<FinanceProcurementReviewLine>>(finder);
      expect(table.rows.last.changedKeys, isEmpty);
      expect(table.rows.last.label, '本次·待核对');
      expect(
        find.text('明细对比 · 修改 0 行 · 删除 0 行 · 新增 0 行 · 待核对 1 行'),
        findsOneWidget,
      );
      expect(find.byType(UtenRevisionFields), findsNothing);
    },
  );

  for (final type in ['PURCHASE', 'SUBCONTRACT']) {
    testWidgets('$type认领失败只读，重试后可审核；续期丢失暂停决定', (tester) async {
      final json = _pendingReviewJson()..['orderType'] = type;
      final repository = _FakeWorkflowRepo(
        FinanceProcurementApprovalReview.fromJson(json),
      );
      final claims = FinanceClaimFixture()..failClaim = true;
      await _pumpReviewPage(tester, repository, claims: claims);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('finance-order-review-approve')),
            )
            .onPressed,
        isNull,
      );
      expect(repository.approved, isEmpty);
      claims.failClaim = false;
      await tester.tap(find.text('重新认领并刷新'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('finance-order-review-approve')));
      await tester.pumpAndSettle();
      claims.loseLease = true;
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      final decision = find.descendant(
        of: find.byKey(const Key('finance-order-review-approve-submit')),
        matching: find.byType(FilledButton),
      );
      expect(tester.widget<FilledButton>(decision).onPressed, isNull);
      expect(repository.approved, isEmpty);
      expect(repository.rejected, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('token 静默刷新（同身份新状态对象/权限滑动）不清空页面与认领', (
    tester,
  ) async {
    final repository = _FakeWorkflowRepo(
      FinanceProcurementApprovalReview.fromJson(_pendingReviewJson()),
    );
    final claims = FinanceClaimFixture();
    await _pumpReviewPage(tester, repository, claims: claims);
    expect(
      find.byKey(const Key('finance-order-review-approve')),
      findsOneWidget,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(FinanceProcurementApprovalReviewPage)),
      listen: false,
    );
    final notifier =
        container.read(sessionProvider.notifier)
            as _FinanceReviewerSessionNotifier;
    // 同内容新实例（token 刷新带回相同档案的历史形态）。
    notifier.state = const SessionState(
      user: AppUser(id: 'finance-reviewer', code: 'FIN001', name: '财务李四'),
    );
    // 权限滑动更新（身份不变、档案内容变化）。
    notifier.state = const SessionState(
      user: AppUser(
        id: 'finance-reviewer',
        code: 'FIN001',
        name: '财务李四',
        permissions: ['finance:extra'],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('登录身份已变化，请重新加载并认领审核'), findsNothing);
    expect(
      find.byKey(const Key('finance-order-review-approve')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<UtenButton>(
            find.byKey(const Key('finance-order-review-approve')),
          )
          .onPressed,
      isNotNull,
    );
    expect(claims.released, isEmpty);
  });
  testWidgets('renders finance-scoped cards with bottom decision bar', (
    tester,
  ) async {
    final repository = _FakeWorkflowRepo(_pendingReview());
    await _pumpReviewPage(tester, repository);

    expect(repository.requestedCaseId, 'case-1');
    expect(find.text('PO-2026-001'), findsOneWidget);
    expect(find.text('采购订货 · 第 2 轮'), findsOneWidget);
    expect(find.text('待财务审核'), findsOneWidget);
    expect(find.text('供应商财务快照 · 供应商A(S-001)'), findsOneWidget);
    expect(find.text('本单金额'), findsOneWidget);
    // 快照卡/总金额列/合计条三处同文案（金额后缀口径下字面相同）。
    expect(find.text('10000.00 美元'), findsWidgets);
    expect(find.text('应付未付'), findsOneWidget);
    expect(find.text('13000.50 美元'), findsOneWidget);
    expect(find.text('可抵预付/贷项'), findsOneWidget);
    expect(find.text('500.00 美元'), findsOneWidget);
    expect(find.text('12500.50 美元'), findsOneWidget, reason: '还差多少与本单同币种');
    expect(find.text('另有 1100.00 元'), findsOneWidget);
    // 折合人民币：快照卡/折合列/合计条三处同文案。
    expect(find.text('71000.00 元'), findsWidgets, reason: '折合人民币带本币单位');
    expect(find.text('美元'), findsWidgets);
    // 2026-10-10 数量+单位内联口径：单位不再单独占列，「100 公斤」在数量格与
    // 合计条各出现一次。
    expect(find.text('铜线'), findsOneWidget);
    expect(find.text('G001'), findsOneWidget);
    expect(find.text('裸色'), findsOneWidget);
    expect(find.text('100 公斤'), findsWidgets);
    expect(find.text('换算率'), findsNothing, reason: '换算率列退役（非货币汇率，误导财务）');
    expect(find.text('PR-2026-010'), findsOneWidget);
    expect(find.text('原因：单价待复核'), findsOneWidget);
    expect(find.byKey(const Key('finance-order-review-back')), findsOneWidget);
    expect(
      find.byKey(const Key('finance-order-review-reject')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('finance-order-review-approve')),
      findsOneWidget,
    );
  });

  testWidgets('approve submits single decision with optional remark', (
    tester,
  ) async {
    final repository = _FakeWorkflowRepo(_pendingReview());
    final router = await _pumpReviewPage(tester, repository);

    await tester.tap(find.byKey(const Key('finance-order-review-approve')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('finance-order-review-approve-remark')),
      '已核对供应商账期',
    );
    await tester.tap(
      find.byKey(const Key('finance-order-review-approve-submit')),
    );
    await tester.pumpAndSettle();

    expect(repository.approved, hasLength(1));
    expect(repository.approved.single.remark, '已核对供应商账期');
    expect(repository.approved.single.exchangeRate, 7.1, reason: '通过提交带当前汇率（快照兜底值）');
    expect(repository.approved.single.items.single.toJson(), {
      'caseId': 'case-1',
      'expectedVersion': 3,
      'expectedClaimId': 'lease-PROCUREMENT_FINANCE_APPROVE-case-1-1',
    });
    // 决策完成 → pop(true) 回任务中心。
    expect(find.text('任务中心列表'), findsOneWidget);
    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      '/finance/procurement-approvals',
    );
  });

  testWidgets('reject requires a reason before submit', (tester) async {
    final repository = _FakeWorkflowRepo(_pendingReview());
    await _pumpReviewPage(tester, repository);

    await tester.tap(find.byKey(const Key('finance-order-review-reject')));
    await tester.pumpAndSettle();
    // 空原因：内联校验拦截，不提交。
    await tester.tap(
      find.byKey(const Key('finance-order-review-reject-submit')),
    );
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message ?? '').contains('请填写驳回原因'),
      ),
      findsOneWidget,
    );
    expect(repository.rejected, isEmpty);

    await tester.enterText(
      find.byKey(const Key('finance-order-review-reject-reason')),
      '税率与结算方式需要重新确认',
    );
    await tester.tap(
      find.byKey(const Key('finance-order-review-reject-submit')),
    );
    await tester.pumpAndSettle();

    expect(repository.rejected, hasLength(1));
    expect(repository.rejected.single.reason, '税率与结算方式需要重新确认');
    expect(find.text('任务中心列表'), findsOneWidget);
  });

  testWidgets('decided case renders read-only without decision bar', (
    tester,
  ) async {
    final repository = _FakeWorkflowRepo(
      _pendingReview(status: 'APPROVED', allowedActions: const {}),
    );
    await _pumpReviewPage(tester, repository);

    expect(find.text('已通过 · 订货已生效'), findsOneWidget);
    expect(find.byKey(const Key('finance-order-review-approve')), findsNothing);
    expect(find.byKey(const Key('finance-order-review-reject')), findsNothing);
    expect(find.byKey(const Key('finance-order-review-back')), findsNothing);
  });

  testWidgets('pending case without server actions stays read-only', (
    tester,
  ) async {
    final repository = _FakeWorkflowRepo(
      _pendingReview(allowedActions: const {}),
    );
    await _pumpReviewPage(tester, repository);

    expect(find.byKey(const Key('finance-order-review-approve')), findsNothing);
    expect(find.byKey(const Key('finance-order-review-reject')), findsNothing);
  });

  for (final type in ['PURCHASE', 'SUBCONTRACT']) {
    testWidgets('$type quantity revision displays complete old and new rows', (
      tester,
    ) async {
      final json = _pendingReviewJson();
      final original = Map<String, dynamic>.from(
        (json['items'] as List).single as Map,
      );
      final withChanges = FinanceProcurementApprovalReview.fromJson({
        ...json,
        'orderType': type,
        'previousItems': [original],
        'items': [
          {
            ...original,
            'qty': '120',
            'amountOriginal': '12000',
            'amountLocal': '85200',
          },
        ],
      });
      await _pumpReviewPage(tester, _FakeWorkflowRepo(withChanges));
      final finder = find.byKey(
        const Key('procurement-approval-revision-table'),
      );
      await tester.scrollUntilVisible(
        finder,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      final table = tester
          .widget<UtenRevisionTable<FinanceProcurementReviewLine>>(finder);
      expect(table.rows.map((row) => row.kind), [
        UtenRevisionKind.removed,
        UtenRevisionKind.added,
      ]);
      expect(table.rows.map((row) => row.value.qty), ['100', '120']);
      expect(table.rows.first.changedKeys, isEmpty);
      expect(table.rows.last.changedKeys, {
        'qty',
        'amountOriginal',
        'amountLocal',
      });
      expect(table.rows.map((row) => row.value.amountOriginal), [
        '10000',
        '12000',
      ]);
      expect(table.rows.every((row) => row.value.goodsName == '铜线'), isTrue);
      expect(table.rows.every((row) => row.value.unitName == '公斤'), isTrue);
      expect(find.text('修改后待复核'), findsOneWidget);
      expect(
        find.text(type == 'PURCHASE' ? '采购订单修改' : '委外订单修改'),
        findsOneWidget,
      );
      expect(find.text('明细对比 · 修改 1 行 · 删除 0 行 · 新增 0 行'), findsOneWidget);
      expect(
        find.byKey(const Key('procurement-approval-qty-changes')),
        findsNothing,
      );
    });
  }

  // ———————————————— 2026-10-10 财务订货审批口径 ————————————————

  Future<UtenRevisionTable<FinanceProcurementReviewLine>> revisionTableOf(
    WidgetTester tester,
  ) async {
    final finder = find.byKey(const Key('procurement-approval-revision-table'));
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    return tester.widget<UtenRevisionTable<FinanceProcurementReviewLine>>(
      finder,
    );
  }

  testWidgets('采购：独立 tableKey + 新默认列序，单位/换算率列退役', (tester) async {
    await _pumpReviewPage(tester, _FakeWorkflowRepo(_pendingReview()));
    final table = await revisionTableOf(tester);
    // 独立 tableKey：不再复用编辑页 purchase.order.items（保存布局按 key 合并
    // 会把本页新键甩到列尾）。
    expect(table.tableKey, 'finance.procurement.review.purchase.items');
    expect(table.columns.map((column) => column.key).toList(), [
      'sourceDocNo',
      'sourceApplicationNos',
      'lineNo',
      'goods',
      'goodsCode',
      'colorName',
      'qty',
      'allowedOverReceiptPct',
      'price',
      'amountOriginal',
      'exchangeRate',
      'amountLocal',
      'deliverDate',
      'remark',
    ]);
    final row = table.rows.single.value;
    // 数量 + 单位内联（formatQtyWithUnit 口径），单位不再单独占列。
    expect(
      table.columns.singleWhere((column) => column.key == 'qty').value(row),
      '100 公斤',
    );
    // 汇率列 = case 级当前汇率；折合人民币 = 总金额 × 当前汇率（默认快照 7.1）。
    expect(
      table.columns
          .singleWhere((column) => column.key == 'exchangeRate')
          .value(row),
      '7.1',
    );
    expect(
      table.columns
          .singleWhere((column) => column.key == 'amountLocal')
          .value(row),
      '71000.00 元',
    );
    expect(table.columns.singleWhere((c) => c.key == 'amountLocal').label,
        '折合人民币');
  });

  testWidgets('委外：独立 tableKey + 允许损耗%占据差异列位', (tester) async {
    final review = FinanceProcurementApprovalReview.fromJson({
      ..._pendingReviewJson(),
      'orderType': 'SUBCONTRACT',
    });
    await _pumpReviewPage(tester, _FakeWorkflowRepo(review));
    final table = await revisionTableOf(tester);
    expect(table.tableKey, 'finance.procurement.review.subcontract.items');
    final keys = table.columns.map((column) => column.key).toList();
    expect(keys.indexOf('allowedLossPct'), keys.indexOf('qty') + 1);
    expect(keys, isNot(contains('allowedOverReceiptPct')));
    expect(table.highlightColumnKeys, contains('allowedLossPct'));
    expect(table.highlightColumnKeys, isNot(contains('allowedOverReceiptPct')));
  });

  testWidgets('采购 highlightColumnKeys：核心核对列 + 允许超收%', (tester) async {
    await _pumpReviewPage(tester, _FakeWorkflowRepo(_pendingReview()));
    final table = await revisionTableOf(tester);
    expect(table.highlightColumnKeys, {
      'qty',
      'price',
      'amountOriginal',
      'amountLocal',
      'allowedOverReceiptPct',
    });
  });

  testWidgets('汇率编辑器：默认快照兜底，编辑实时重算折合人民币列与合计', (tester) async {
    await _pumpReviewPage(tester, _FakeWorkflowRepo(_pendingReview()));
    final field = find.byKey(const Key('finance-order-review-rate-field'));
    expect(
      tester.widget<TextField>(field).controller?.text,
      '7.1',
      reason: 'financeExchangeRate 为空 → 提交快照 exchangeRate 兜底',
    );

    await tester.enterText(field, '6.5');
    await tester.pump();
    final table = await revisionTableOf(tester);
    final row = table.rows.single.value;
    expect(
      table.columns
          .singleWhere((column) => column.key == 'exchangeRate')
          .value(row),
      '6.5',
    );
    expect(
      table.columns
          .singleWhere((column) => column.key == 'amountLocal')
          .value(row),
      '65000.00 元',
    );
    expect(
      find.descendant(
        of: find.byType(UtenTotalsSummaryBar),
        matching: find.text('65000.00 元'),
      ),
      findsOneWidget,
      reason: '合计条折合人民币随汇率联动重算',
    );
  });

  testWidgets('汇率全缺省时兜底 1', (tester) async {
    final json = {..._pendingReviewJson()}..remove('exchangeRate');
    await _pumpReviewPage(
      tester,
      _FakeWorkflowRepo(FinanceProcurementApprovalReview.fromJson(json)),
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('finance-order-review-rate-field')),
          )
          .controller
          ?.text,
      '1',
    );
    final table = await revisionTableOf(tester);
    expect(
      table.columns
          .singleWhere((column) => column.key == 'amountLocal')
          .value(table.rows.single.value),
      '10000.00 元',
    );
  });

  testWidgets('已批 case：汇率只读显示 financeExchangeRate，无编辑框', (tester) async {
    final review = FinanceProcurementApprovalReview.fromJson({
      ..._pendingReviewJson(),
      'status': 'APPROVED',
      'allowedActions': const <String>[],
      'financeExchangeRate': '6.8',
    });
    await _pumpReviewPage(tester, _FakeWorkflowRepo(review));
    expect(
      find.byKey(const Key('finance-order-review-rate-field')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('finance-order-review-rate-readonly')),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(
        find.byKey(const Key('finance-order-review-rate-readonly')),
      ).data,
      '6.8',
      reason: '只读汇率行显示财务落定的 financeExchangeRate（表内汇率列同值）',
    );
    final table = await revisionTableOf(tester);
    expect(
      table.columns
          .singleWhere((column) => column.key == 'amountLocal')
          .value(table.rows.single.value),
      '68000.00 元',
    );
  });

  testWidgets('汇率非法（0/空）时通过被拦截，不提交', (tester) async {
    final repository = _FakeWorkflowRepo(_pendingReview());
    await _pumpReviewPage(tester, repository);
    final field = find.byKey(const Key('finance-order-review-rate-field'));

    await tester.enterText(field, '0');
    await tester.pump();
    await tester.tap(find.byKey(const Key('finance-order-review-approve')));
    await tester.pumpAndSettle();
    expect(repository.approved, isEmpty);
    // 2026-10-10 字段消息契约：错误文案收进格内 ⓘ（Tooltip），不再有裸 errorText。
    expect(find.byTooltip('汇率必须是大于 0 的数字'), findsOneWidget);

    await tester.enterText(field, '');
    await tester.pump();
    await tester.tap(find.byKey(const Key('finance-order-review-approve')));
    await tester.pumpAndSettle();
    expect(repository.approved, isEmpty);
    expect(find.byTooltip('请填写大于 0 的汇率'), findsOneWidget);
  });

  testWidgets('通过提交带编辑后的汇率', (tester) async {
    final repository = _FakeWorkflowRepo(_pendingReview());
    await _pumpReviewPage(tester, repository);
    await tester.enterText(
      find.byKey(const Key('finance-order-review-rate-field')),
      '6.5',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('finance-order-review-approve')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('finance-order-review-approve-submit')),
    );
    await tester.pumpAndSettle();
    expect(repository.approved.single.exchangeRate, 6.5);
  });

  testWidgets('供应商红色加粗：快照卡标题与订单信息卡供应商值', (tester) async {
    await _pumpReviewPage(tester, _FakeWorkflowRepo(_pendingReview()));
    final theme = Theme.of(tester.element(find.text('PO-2026-001')));
    final title = tester.widget<Text>(
      find.text('供应商财务快照 · 供应商A(S-001)'),
    );
    expect(title.style?.color, theme.colorScheme.error);
    expect(title.style?.fontWeight, FontWeight.w800);
    final supplier = tester.widget<Text>(find.text('供应商A'));
    expect(supplier.style?.color, theme.colorScheme.error);
    expect(supplier.style?.fontWeight, FontWeight.w700);
  });
}
