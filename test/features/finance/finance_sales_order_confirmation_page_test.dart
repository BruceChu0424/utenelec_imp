import 'package:flutter/material.dart';
import 'package:uten_imp/components/data_display/uten_revision_table.dart';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/payment_style_repository.dart';
import 'package:uten_imp/features/finance/providers/finance_name_provider.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:uten_imp/shared/models/party_open_balance.dart';
import 'package:uten_imp/shared/models/task_claim_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/models/sales_order_finance_confirmation.dart';
import 'package:uten_imp/features/finance/pages/finance_sales_order_confirmation_page.dart';
import 'package:uten_imp/features/finance/pages/finance_sales_order_review_page.dart';
import 'package:uten_imp/features/finance/repositories/sales_order_finance_confirmation_repository.dart';
import 'package:uten_imp/shared/repositories/task_claim_repository.dart';
import '../../helpers/finance_claim_fixture.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

import '../../helpers/badge_summary_fixture.dart';

class _FakeConfirmationRepository
    implements SalesOrderFinanceConfirmationRepository {
  @override
  Future<List<MasterFacetBucket>> billNoFacets({
    bool? rejected,
    String? keyword,
    bool? changesOnly,
  }) async => const []; // 2026-09-25 单号列统一：页面 facets 静默降级。
  _FakeConfirmationRepository(this.items, {this.reviewValue});

  final List<SalesOrderFinancePendingItem> items;
  final SalesOrderFinanceReview? reviewValue;
  final List<String?> keywords = [];
  final List<List<String>> batchIds = [];
  final List<String?> batchRemarks = [];
  final List<int?> confirmedRevisions = [];
  final List<String> reviewedIds = [];

  @override
  Future<SalesOrderFinancePendingPage> pending({
    int page = 1,
    int size = 20,
    bool? rejected,
    String? keyword,
    bool? changesOnly,
    String? sort,
    String? order,
    String? billNo,
  }) async {
    keywords.add(keyword);
    final normalized = keyword?.toLowerCase().trim() ?? '';
    final filtered = items
        .where((item) => rejected == null || item.financeRejected == rejected)
        .where(
          (item) =>
              normalized.isEmpty ||
              item.billNo.toLowerCase().contains(normalized) ||
              (item.clientName ?? '').toLowerCase().contains(normalized) ||
              (item.sellerName ?? '').toLowerCase().contains(normalized),
        )
        .toList(growable: false);
    return SalesOrderFinancePendingPage(
      items: filtered,
      page: 1,
      size: size,
      total: filtered.length,
      totalPages: 1,
    );
  }

  @override
  Future<int> pendingCount({bool? changesOnly}) async =>
      items.where((item) => !item.financeRejected).length;

  @override
  Future<SalesOrderFinanceReview> review(String orderId) async {
    reviewedIds.add(orderId);
    return reviewValue ??
        SalesOrderFinanceReview(
          orderId: orderId,
          billNo: items.firstWhere((item) => item.orderId == orderId).billNo,
          financeReviewRevision: items
              .firstWhere((item) => item.orderId == orderId)
              .financeReviewRevision,
        );
  }

  @override
  Future<void> confirm(
    String orderId, {
    String? remark,
    int? expectedRevision,
    String? expectedClaimId,
  }) async {
    confirmedRevisions.add(expectedRevision);
  }

  @override
  Future<void> confirmBatch(
    Iterable<String> orderIds, {
    String? remark,
    Map<String, int>? expectedRevisions,
    Map<String, String>? expectedClaimIds,
  }) async {
    final ids = orderIds.toList(growable: false);
    batchIds.add(ids);
    batchRemarks.add(remark);
    items.removeWhere((item) => ids.contains(item.orderId));
  }

  @override
  Future<void> reject(
    String orderId, {
    required String reason,
    int? expectedRevision,
    String? expectedClaimId,
  }) async {}
}

class _FinanceSessionNotifier extends SessionNotifier {
  void replaceIdentity() => state = const SessionState(
    user: AppUser(id: 'finance-other', code: 'FIN002', name: '另一财务'),
  );
  @override
  SessionState build() => const SessionState(
    user: AppUser(id: 'finance-user', code: 'FIN001', name: '财务审核员'),
  );
}

SalesOrderFinancePendingItem _item({
  required String id,
  required String billNo,
  String client = '远硕智能',
  bool rejected = false,
  int changeCount = 0,
  PartyOpenBalance balance = const PartyOpenBalance(
    currencyName: '美金',
    openOriginal: '12000.00',
    netOriginal: '12000.00',
    baseCurrencyName: '人民币',
  ),
}) => SalesOrderFinancePendingItem(
  orderId: id,
  billNo: billNo,
  billDate: '2026-08-29',
  clientName: client,
  sellerName: '系统管理员',
  deliverDate: '2026-09-30',
  itemCount: 3,
  totalOriginal: '144000.00',
  currencyCode: 'USD',
  currencyName: '美金',
  clientBalance: balance,
  financeRejected: rejected,
  financeRejectedReason: rejected ? '客户额度待核对' : null,
  changeCount: changeCount,
);

Future<GoRouter> _pumpPage(
  WidgetTester tester,
  _FakeConfirmationRepository repository, {
  required Size size,
  bool canConfirm = true,
  FinanceClaimFixture? claims,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = GoRouter(
    initialLocation: '/finance/sales-order-confirmations',
    routes: [
      GoRoute(
        path: '/finance/sales-order-confirmations',
        builder: (_, _) => const FinanceSalesOrderConfirmationPage(),
        routes: [
          GoRoute(
            path: ':id',
            builder: (_, state) =>
                Scaffold(body: Text('detail-${state.pathParameters['id']}')),
          ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        isSuperAdminProvider.overrideWithValue(false),
        currentPermissionsProvider.overrideWithValue({
          Perm.salesOrderFinanceView,
          if (canConfirm) Perm.salesOrderFinanceConfirm,
        }),
        sessionProvider.overrideWith(_FinanceSessionNotifier.new),
        // 客户应收列前缀读本位币名(币种字典)：确认页 initState 会拉字典，
        // 这里换成一个不发网的空服务(测试里应收列退回裸金额)。
        _offlineFinanceNameServiceOverride,
        taskClaimRepositoryProvider.overrideWithValue(
          claims ?? FinanceClaimFixture(),
        ),
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(
            facts: {BadgeFact.salesOrderFinance: repository.items.length},
          ),
        ),
        salesOrderFinanceConfirmationRepositoryProvider.overrideWithValue(
          repository,
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

/// 离线版名称服务：Dio 无 adapter，字典加载在 ensureLoaded 内部被容错吞掉，
/// 页面正常渲染（本位币名缺失时应收列显示裸金额）。
final _offlineFinanceNameServiceOverride = financeNameServiceProvider
    .overrideWith(
      (ref) =>
          FinanceNameService(ApiClient(Dio()), _NoopPaymentStyleRepository()),
    );

class _NoopPaymentStyleRepository implements PaymentStyleRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not needed in this test');
}

Future<void> _pumpReview(
  WidgetTester tester,
  SalesOrderFinanceReview review, {
  FinanceClaimFixture? claims,
  _FakeConfirmationRepository? repository,
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(900, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        isSuperAdminProvider.overrideWithValue(false),
        currentPermissionsProvider.overrideWithValue({
          Perm.salesOrderFinanceView,
          Perm.salesOrderFinanceConfirm,
        }),
        sessionProvider.overrideWith(_FinanceSessionNotifier.new),
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(facts: {BadgeFact.salesOrderFinance: 0}),
        ),
        salesOrderFinanceConfirmationRepositoryProvider.overrideWithValue(
          repository ?? _FakeConfirmationRepository([], reviewValue: review),
        ),
        // A successful decision requires an explicitly owned live lease.
        taskClaimRepositoryProvider.overrideWithValue(
          claims ?? FinanceClaimFixture(),
        ),
      ],
      child: MaterialApp(home: FinanceSalesOrderReviewPage(id: review.orderId)),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  for (final size in [const Size(1200, 900), const Size(390, 844)]) {
    testWidgets(
      'pending category owns the full queue badge without the summary card at $size',
      (tester) async {
        final repository = _FakeConfirmationRepository([
          _item(id: 'one', billNo: 'XD-ONE'),
          _item(id: 'two', billNo: 'XD-TWO'),
          _item(id: 'rejected', billNo: 'XD-REJECTED', rejected: true),
        ]);
        await _pumpPage(tester, repository, size: size);
        UtenSegmentBadgeLabel pendingBadge() =>
            tester.widget<UtenSegmentBadgeLabel>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is UtenSegmentBadgeLabel && widget.label == '待确认',
              ),
            );
        expect(
          find.byKey(const Key('sales-order-finance-summary')),
          findsNothing,
        );
        expect(find.textContaining('待财务放行'), findsNothing);
        expect(pendingBadge().count, 2);
        final search = find.descendant(
          of: find.byKey(const Key('sales-order-finance-search')),
          matching: find.byType(TextField),
        );
        await tester.enterText(search, 'XD-ONE');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(
          pendingBadge().count,
          2,
          reason:
              'Badge follows the full queue, not the filtered visible row count.',
        );
        await tester.tap(find.text('已驳回'));
        await tester.pumpAndSettle();
        expect(pendingBadge().count, 2);
        final rejected = tester.widget<UtenSegmentBadgeLabel>(
          find.byWidgetPredicate(
            (widget) =>
                widget is UtenSegmentBadgeLabel && widget.label == '已驳回',
          ),
        );
        // 2026-09-21 用户口径: 父分类有红徽章, 子分类也要有数; ADR-100 起已驳回段
        // 挂黄色进行中徽章(单子退回销售手上、还会再回到本页, 既非终态也不用财务
        // 现在动手), 数字取自 rejected=true 的全量 total, 不进任何累加。
        expect(rejected.count, 1);
        expect(rejected.countForm, UtenSegmentCountForm.inProgress);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets('销售批量任一认领失败则整批不提交并释放已取得的认领', (tester) async {
    final repository = _FakeConfirmationRepository([
      _item(id: 'order-1', billNo: 'XD001'),
      _item(id: 'order-2', billNo: 'XD002'),
    ]);
    final claims = FinanceClaimFixture()..failClaimKey = 'order-2';
    await _pumpPage(
      tester,
      repository,
      size: const Size(1440, 1000),
      claims: claims,
    );
    final table = tester
        .widget<MasterDataTableView<SalesOrderFinancePendingItem>>(
          find.byKey(const Key('sales-order-finance-desktop-table')),
        );
    table.onSelectedIdsChanged?.call({'order-1', 'order-2'});
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('sales-order-finance-batch-confirm')),
    );
    await tester.pumpAndSettle();
    expect(repository.batchIds, isEmpty);
    expect(claims.released, ['lease-SALES_ORDER_FINANCE_CONFIRM-order-1-1']);
  });

  testWidgets('销售批量认领后发现版本变化不会换用新版本偷偷提交', (tester) async {
    final repository = _FakeConfirmationRepository(
      [_item(id: 'order-1', billNo: 'XD001')],
      reviewValue: const SalesOrderFinanceReview(
        orderId: 'order-1',
        billNo: 'XD001',
        financeReviewRevision: 99,
      ),
    );
    await _pumpPage(tester, repository, size: const Size(1440, 1000));
    final table = tester
        .widget<MasterDataTableView<SalesOrderFinancePendingItem>>(
          find.byKey(const Key('sales-order-finance-desktop-table')),
        );
    table.onSelectedIdsChanged?.call({'order-1'});
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('sales-order-finance-batch-confirm')),
    );
    await tester.pumpAndSettle();
    expect(repository.batchIds, isEmpty);
    expect(repository.reviewedIds, ['order-1']);
  });

  testWidgets('认领网络失败只读，显式重试后才恢复初审和修改审批', (tester) async {
    const review = SalesOrderFinanceReview(
      orderId: 'order-guard',
      billNo: 'XD-GUARD',
      financeReviewRevision: 7,
    );
    final claims = FinanceClaimFixture()..failClaim = true;
    final repository = _FakeConfirmationRepository([], reviewValue: review);
    await _pumpReview(tester, review, claims: claims, repository: repository);
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('finance-review-confirm')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('finance-review-reject')))
          .onPressed,
      isNull,
    );
    expect(repository.confirmedRevisions, isEmpty);
    claims.failClaim = false;
    await tester.tap(find.text('重新认领并刷新'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('finance-review-confirm')))
          .onPressed,
      isNotNull,
    );
    expect(claims.acquired, ['order-guard', 'order-guard']);
  });

  testWidgets('提交前续租失败不发送财审决定，原版本不被偷换', (tester) async {
    const review = SalesOrderFinanceReview(
      orderId: 'order-guard',
      billNo: 'XD-GUARD',
      financeReviewRevision: 7,
    );
    final claims = FinanceClaimFixture();
    final repository = _FakeConfirmationRepository([], reviewValue: review);
    await _pumpReview(tester, review, claims: claims, repository: repository);
    await tester.tap(find.byKey(const Key('finance-review-confirm')));
    await tester.pumpAndSettle();
    claims.failHeartbeat = true;
    await tester.tap(find.byKey(const Key('finance-review-confirm-submit')));
    await tester.pumpAndSettle();
    expect(repository.confirmedRevisions, isEmpty);
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('finance-review-confirm')))
          .onPressed,
      isNull,
    );
    expect(find.textContaining('已暂停审核'), findsWidgets);
  });

  testWidgets('认领回包晚于页面销毁时不恢复审核或发出决定', (tester) async {
    const review = SalesOrderFinanceReview(
      orderId: 'order-guard',
      billNo: 'XD-GUARD',
    );
    final claims = FinanceClaimFixture()
      ..pendingClaim = Completer<TaskClaimView?>();
    final repository = _FakeConfirmationRepository([], reviewValue: review);
    await _pumpReview(
      tester,
      review,
      claims: claims,
      repository: repository,
      settle: false,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    claims.pendingClaim!.complete(
      claims.lease('SALES_ORDER_FINANCE_CONFIRM', 'order-guard'),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(repository.confirmedRevisions, isEmpty);
  });

  testWidgets('认领期间身份切换忽略旧回包并保留重新加载入口', (tester) async {
    const review = SalesOrderFinanceReview(
      orderId: 'order-guard',
      billNo: 'XD-GUARD',
    );
    final claims = FinanceClaimFixture()
      ..pendingClaim = Completer<TaskClaimView?>();
    final repository = _FakeConfirmationRepository([], reviewValue: review);
    await _pumpReview(
      tester,
      review,
      claims: claims,
      repository: repository,
      settle: false,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(FinanceSalesOrderReviewPage)),
      listen: false,
    );
    (container.read(sessionProvider.notifier) as _FinanceSessionNotifier)
        .replaceIdentity();
    claims.pendingClaim!.complete(
      claims.lease('SALES_ORDER_FINANCE_CONFIRM', 'order-guard'),
    );
    await tester.pumpAndSettle();
    expect(find.text('登录身份已变化，请重新加载并认领审核'), findsOneWidget);
    expect(find.byKey(const Key('finance-review-confirm')), findsNothing);
    expect(repository.confirmedRevisions, isEmpty);
  });
  testWidgets('桌面端使用自研多选表格，单击选择后可原子批量确认', (tester) async {
    final repository = _FakeConfirmationRepository([
      _item(id: 'order-1', billNo: 'XD20260829000003'),
      _item(id: 'order-2', billNo: 'XD20260829000004', client: '测试客户'),
    ]);
    await _pumpPage(tester, repository, size: const Size(1440, 1000));

    expect(
      find.byKey(const Key('sales-order-finance-desktop-table')),
      findsOneWidget,
    );
    final table = tester
        .widget<MasterDataTableView<SalesOrderFinancePendingItem>>(
          find.byKey(const Key('sales-order-finance-desktop-table')),
        );
    expect(table.selectable, isTrue);
    expect(find.text('订单金额'), findsOneWidget);
    expect(find.text('客户应收'), findsOneWidget);

    await tester.tap(find.text('XD20260829000003'));
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('sales-order-finance-batch-confirm')),
    );
    await tester.pumpAndSettle();

    expect(find.text('批量确认 1 笔销售订单'), findsOneWidget);
    expect(find.textContaining('任一订单校验失败时全部不放行'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('sales-order-finance-batch-remark')),
      '已逐笔核对',
    );
    await tester.tap(find.byKey(const Key('sales-order-finance-batch-submit')));
    await tester.pumpAndSettle();

    expect(repository.batchIds, [
      ['order-1'],
    ]);
    expect(repository.batchRemarks, ['已逐笔核对']);
    expect(find.text('XD20260829000003'), findsNothing);
  });

  testWidgets('修改后的订单在队列标注变更次数', (tester) async {
    await _pumpPage(
      tester,
      _FakeConfirmationRepository([
        _item(id: 'ord-1', billNo: 'XD-001', changeCount: 2),
        _item(id: 'ord-2', billNo: 'XD-002'),
      ]),
      size: const Size(1400, 900),
    );

    expect(find.text('修改后待确认 · 2 次变更'), findsOneWidget);
    expect(find.text('待财务确认'), findsOneWidget);
  });

  testWidgets('桌面同行 350ms 内双击进入现有审核详情', (tester) async {
    final repository = _FakeConfirmationRepository([
      _item(id: 'order-1', billNo: 'XD20260829000003'),
    ]);
    await _pumpPage(tester, repository, size: const Size(1440, 1000));

    await tester.tap(find.text('XD20260829000003'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('XD20260829000003'));
    await tester.pumpAndSettle();

    expect(find.text('detail-order-1'), findsOneWidget);
  });

  testWidgets('客户应收列与订单同币种：还差多少写「币种 金额」，其它币种与历史应收放进提示', (tester) async {
    final repository = _FakeConfirmationRepository([
      _item(
        id: 'order-1',
        billNo: 'XD-SURPLUS',
        balance: const PartyOpenBalance(
          currencyName: '美金',
          creditOriginal: '200.0000',
          netOriginal: '-200.0000',
          baseCurrencyName: '人民币',
        ),
      ),
      _item(
        id: 'order-2',
        billNo: 'XD-OWES',
        balance: const PartyOpenBalance(
          currencyName: '美金',
          openOriginal: '12000',
          netOriginal: '12000',
          baseCurrencyName: '人民币',
          otherCurrencies: [
            PartyCurrencyBalance(currencyName: '人民币', netOriginal: '30000'),
          ],
          unverifiedLocal: '1200',
          unverifiedCount: 1,
          openBookLocal: '116400',
          creditLimitLocal: '50000',
          overLimitLocal: '66400',
          overCredit: true,
        ),
      ),
    ]);
    await _pumpPage(tester, repository, size: const Size(1440, 1000));

    expect(find.text('美金 144000.00'), findsNWidgets(2));
    expect(find.text('预收有余 美金 200.00'), findsOneWidget);
    expect(find.text('美金 12000.00'), findsOneWidget);
    final owes = tester.widget<Text>(find.text('美金 12000.00'));
    expect(
      owes.style?.color,
      Theme.of(tester.element(find.text('美金 12000.00'))).colorScheme.error,
      reason: '全部币种应收(折本币)超信用额度时该格标红',
    );
    final tooltip = tester.widget<Tooltip>(
      find
          .ancestor(
            of: find.text('美金 12000.00'),
            matching: find.byType(Tooltip),
          )
          .first,
    );
    expect(
      tooltip.message,
      '另有 人民币 30000.00；另有历史应收 人民币 1200.00 原币未核实；'
      '全部币种应收(折本币) 人民币 116400.00 已超信用额度 人民币 50000.00',
    );
    expect(
      find.ancestor(
        of: find.text('预收有余 美金 200.00'),
        matching: find.byType(Tooltip),
      ),
      findsNothing,
      reason: '没有补充说明时不挂提示',
    );
  });

  testWidgets('紧凑端客户应收同样按订单币种，补充说明另起一行', (tester) async {
    final repository = _FakeConfirmationRepository([
      _item(
        id: 'order-1',
        billNo: 'XD-COMPACT',
        balance: const PartyOpenBalance(
          currencyName: '美金',
          netOriginal: '-200',
          otherCurrencies: [
            PartyCurrencyBalance(currencyName: '人民币', netOriginal: '30000'),
          ],
        ),
      ),
    ]);
    await _pumpPage(tester, repository, size: const Size(375, 812));

    expect(find.textContaining('客户应收 预收有余 美金 200.00'), findsOneWidget);
    expect(find.text('另有 人民币 30000.00'), findsOneWidget);
    expect(find.textContaining('美金 144000.00'), findsWidgets);
  });

  testWidgets('审核详情客户快照：本单金额与客户应收同币种，超信用出横幅', (tester) async {
    const review = SalesOrderFinanceReview(
      orderId: 'order-credit',
      billNo: 'XD-CREDIT',
      clientName: '远硕智能',
      clientCode: 'C001',
      currencyName: '美金',
      totalOriginal: '144000.0000',
      clientCreditFloor: '2000',
      clientBalance: PartyOpenBalance(
        currencyName: '美金',
        openOriginal: '500',
        creditOriginal: '100',
        netOriginal: '400',
        baseCurrencyName: '人民币',
        openBookLocal: '3500',
        creditLimitLocal: '3000',
        overLimitLocal: '500',
        overCredit: true,
      ),
    );
    await _pumpReview(tester, review);

    expect(find.text('客户财务快照 · 远硕智能(C001)'), findsOneWidget);
    expect(find.text('美金 144000.00'), findsWidgets);
    expect(find.text('美金 500.00'), findsOneWidget);
    expect(find.text('美金 100.00'), findsOneWidget);
    expect(find.text('美金 400.00'), findsOneWidget);
    expect(find.text('人民币 3500.00'), findsOneWidget);
    expect(find.text('人民币 3000.00'), findsOneWidget);
    expect(find.text('人民币 2000.00'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('finance-party-snapshot-over-limit')),
      findsOneWidget,
    );
    expect(find.textContaining('已超信用额度，请谨慎确认'), findsOneWidget);
  });

  testWidgets('紧凑端使用可勾选列表并保留显式详情入口', (tester) async {
    final repository = _FakeConfirmationRepository([
      _item(id: 'order-1', billNo: 'XD20260829000003'),
    ]);
    await _pumpPage(tester, repository, size: const Size(375, 812));

    expect(
      find.byKey(const Key('sales-order-finance-mobile-list')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('sales-order-finance-desktop-table')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('sales-order-finance-review-order-1')),
      findsOneWidget,
    );
    expect(find.text('已选 0 项'), findsOneWidget);
  });

  testWidgets('搜索走服务端关键词，只有查看权限时表格保持只读', (tester) async {
    final repository = _FakeConfirmationRepository([
      _item(id: 'order-1', billNo: 'XD20260829000003'),
    ]);
    await _pumpPage(
      tester,
      repository,
      size: const Size(1440, 1000),
      canConfirm: false,
    );

    final table = tester
        .widget<MasterDataTableView<SalesOrderFinancePendingItem>>(
          find.byKey(const Key('sales-order-finance-desktop-table')),
        );
    expect(table.selectable, isFalse);
    expect(
      find.byKey(const Key('sales-order-finance-batch-confirm')),
      findsNothing,
    );

    await tester.enterText(
      find.byKey(const Key('sales-order-finance-search')),
      '远硕',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(repository.keywords.last, '远硕');
  });

  testWidgets('已驳回详情只读，不能越过销售修订直接确认', (tester) async {
    await _pumpReview(
      tester,
      const SalesOrderFinanceReview(
        orderId: 'order-rejected',
        billNo: 'XD-REJECTED',
        financeRejected: true,
        financeRejectedReason: '客户额度待核对',
      ),
    );

    expect(find.text('已驳回 · 待销售修改'), findsOneWidget);
    expect(find.byKey(const Key('finance-review-confirm')), findsNothing);
    expect(find.byKey(const Key('finance-review-reject')), findsNothing);
  });

  testWidgets('确认后只改数量也显示完整旧行划线和新行，保留审核操作', (tester) async {
    await _pumpReview(
      tester,
      const SalesOrderFinanceReview(
        orderId: 'order-changed',
        billNo: 'XD-CHANGED',
        revisionDiff: SalesOrderRevisionDiff(
          beforeItems: [
            SalesOrderRevisionLine(
              itemId: 'item-1',
              goodsCode: 'QTY-RC-001',
              goodsName: '改量复核测试货品',
              values: {'数量': '10', '单位': '个', '单价': '5', '原币金额': '50'},
            ),
          ],
          afterItems: [
            SalesOrderRevisionLine(
              itemId: 'item-1',
              goodsCode: 'QTY-RC-001',
              goodsName: '改量复核测试货品',
              values: {'数量': '6', '单位': '个', '单价': '5', '原币金额': '30'},
            ),
          ],
          changedItemIds: {'item-1'},
          headerChanges: [],
        ),
      ),
    );
    expect(find.text('修改后待复审'), findsOneWidget);
    expect(find.text('销售订单修改审核'), findsOneWidget);
    final heading = tester.widget<Text>(
      find.byKey(const Key('sales-order-revision-heading')),
    );
    expect(heading.data, '销售订单修改');
    expect(heading.style!.fontWeight, FontWeight.w800);
    expect(find.byKey(const Key('sales-order-revision-table')), findsOneWidget);
    final diff = tester.widget<UtenRevisionTable<SalesOrderRevisionLine>>(
      find.byType(UtenRevisionTable<SalesOrderRevisionLine>),
    );
    expect(diff.rows.map((row) => row.kind), [
      UtenRevisionKind.removed,
      UtenRevisionKind.added,
    ]);
    expect(diff.rows.map((row) => row.value.values['数量']), ['10', '6']);
    expect(diff.rows.map((row) => row.value.goodsName), [
      '改量复核测试货品',
      '改量复核测试货品',
    ]);
    expect(find.byType(UtenRevisionStrike), findsOneWidget);
    expect(find.byKey(const Key('finance-review-confirm')), findsOneWidget);
  });

  testWidgets('已确认订单深链显示真实确认状态', (tester) async {
    await _pumpReview(
      tester,
      const SalesOrderFinanceReview(
        orderId: 'order-confirmed',
        billNo: 'XD-CONFIRMED',
        financeConfirmed: true,
        financeConfirmedByName: '财务审核员',
        financeConfirmedAt: '2026-08-29T10:00:00+08:00',
      ),
    );

    expect(find.textContaining('已财务确认'), findsOneWidget);
    expect(find.byKey(const Key('finance-review-confirm')), findsNothing);
    expect(find.byKey(const Key('finance-review-reject')), findsNothing);
  });

  // 回归（v2026.09.03-1 现场）：V459 审核弹窗「去审核」router.go 直达审核页时
  // 路由栈空，确认成功后 context.pop(true) 抛 GoError 被外层 catch 吞掉，
  // 误报「确认失败，请稍后重试」而实际后端已成功。
  Future<GoRouter> pumpDecisionFlow(
    WidgetTester tester, {
    required bool push,
    bool changes = false,
    String action = 'confirm',
  }) async {
    tester.view.physicalSize = const Size(900, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _FakeConfirmationRepository(
      [],
      reviewValue: const SalesOrderFinanceReview(
        orderId: 'order-1',
        billNo: 'XD20260829000003',
      ),
    );
    final source = changes
        ? '/finance/sales-order-changes'
        : '/finance/sales-order-confirmations';
    final reviewRoute = Uri(
      path: '/finance/sales-order-confirmations/order-1',
      queryParameters: {'returnTo': source},
    ).toString();
    final router = GoRouter(
      initialLocation: push ? source : reviewRoute,
      routes: [
        // 与生产路由同构（app_router.dart）：审核页是列表页的兄弟路由而非子路由
        // ——深链直达时栈里只有审核页（canPop=false → go 兜底回 returnTo），
        // push 进入时栈下是打开方（pop(true) 交回刷新）。若嵌成子路由，父页面
        // 也会压栈，canPop 语义就与线上不一致了。
        GoRoute(
          path: '/finance/sales-order-confirmations',
          builder: (_, _) => const Text('确认列表页'),
        ),
        GoRoute(
          path: '/finance/sales-order-confirmations/order-1',
          builder: (_, state) => FinanceSalesOrderReviewPage(
            id: state.pathParameters['id'] ?? 'order-1',
            returnTo: state.uri.queryParameters['returnTo'],
          ),
        ),
        GoRoute(
          path: '/finance/sales-order-changes',
          builder: (_, _) => const Text('修改列表页'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isSuperAdminProvider.overrideWithValue(false),
          currentPermissionsProvider.overrideWithValue({
            Perm.salesOrderFinanceView,
            Perm.salesOrderFinanceConfirm,
          }),
          sessionProvider.overrideWith(_FinanceSessionNotifier.new),
          _offlineFinanceNameServiceOverride,
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(facts: {BadgeFact.salesOrderFinance: 0}),
          ),
          salesOrderFinanceConfirmationRepositoryProvider.overrideWithValue(
            repository,
          ),
          taskClaimRepositoryProvider.overrideWithValue(FinanceClaimFixture()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    if (push) {
      router.push(reviewRoute);
    }
    await tester.pumpAndSettle();

    if (action == 'back') {
      tester
          .widget<UtenBackButton>(find.byType(UtenBackButton))
          .onPressed
          ?.call();
      await tester.pumpAndSettle();
      return router;
    }
    await tester.tap(
      find.byKey(
        Key('finance-review-${action == 'reject' ? 'reject' : 'confirm'}'),
      ),
    );
    await tester.pumpAndSettle();
    if (action == 'reject') {
      await tester.enterText(
        find.byKey(const Key('finance-review-reject-reason')),
        '请核对修改后的数量',
      );
      await tester.pump();
    }
    await tester.tap(
      find.byKey(
        Key(
          'finance-review-${action == 'reject' ? 'reject' : 'confirm'}-submit',
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('弹窗 go 直达：确认通过后回列表页且不误报确认失败', (tester) async {
    await pumpDecisionFlow(tester, push: false);

    expect(find.text('确认失败，请稍后重试'), findsNothing);
    expect(find.text('确认列表页'), findsOneWidget);
  });

  testWidgets('列表 push 进入：确认通过后 pop 回列表（返回值路径不受影响）', (tester) async {
    await pumpDecisionFlow(tester, push: true);

    expect(find.text('确认失败，请稍后重试'), findsNothing);
    expect(find.text('确认列表页'), findsOneWidget);
  });

  for (final action in ['confirm', 'reject', 'back']) {
    testWidgets('修改队列深链审核$action后仍回修改队列', (tester) async {
      await pumpDecisionFlow(
        tester,
        push: false,
        changes: true,
        action: action,
      );
      expect(find.text('修改列表页'), findsOneWidget);
      expect(find.text('确认列表页'), findsNothing);
    });
  }
}
