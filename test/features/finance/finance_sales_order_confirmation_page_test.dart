import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/models/sales_order_finance_confirmation.dart';
import 'package:uten_imp/features/finance/pages/finance_sales_order_confirmation_page.dart';
import 'package:uten_imp/features/finance/pages/finance_sales_order_review_page.dart';
import 'package:uten_imp/features/finance/providers/sales_order_finance_confirmation_count_provider.dart';
import 'package:uten_imp/features/finance/repositories/sales_order_finance_confirmation_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

class _FakeConfirmationRepository
    implements SalesOrderFinanceConfirmationRepository {
  _FakeConfirmationRepository(this.items, {this.reviewValue});

  final List<SalesOrderFinancePendingItem> items;
  final SalesOrderFinanceReview? reviewValue;
  final List<String?> keywords = [];
  final List<List<String>> batchIds = [];
  final List<String?> batchRemarks = [];

  @override
  Future<SalesOrderFinancePendingPage> pending({
    int page = 1,
    int size = 20,
    bool? rejected,
    String? keyword,
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
  Future<int> pendingCount() async =>
      items.where((item) => !item.financeRejected).length;

  @override
  Future<SalesOrderFinanceReview> review(String orderId) async =>
      reviewValue ??
      (throw StateError('reviewValue is required for the review page test'));

  @override
  Future<void> confirm(String orderId, {String? remark}) async {}

  @override
  Future<void> confirmBatch(Iterable<String> orderIds, {String? remark}) async {
    final ids = orderIds.toList(growable: false);
    batchIds.add(ids);
    batchRemarks.add(remark);
    items.removeWhere((item) => ids.contains(item.orderId));
  }

  @override
  Future<void> reject(String orderId, {required String reason}) async {}
}

class _FinanceSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    user: AppUser(id: 'finance-user', code: 'FIN001', name: '财务审核员', roles: []),
  );
}

SalesOrderFinancePendingItem _item({
  required String id,
  required String billNo,
  String client = '远硕智能',
  bool rejected = false,
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
  clientOutstanding: '12000.00',
  financeRejected: rejected,
  financeRejectedReason: rejected ? '客户额度待核对' : null,
);

Future<GoRouter> _pumpPage(
  WidgetTester tester,
  _FakeConfirmationRepository repository, {
  required Size size,
  bool canConfirm = true,
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
        salesOrderFinanceConfirmationCountProvider.overrideWith(
          (ref) async => repository.items.length,
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

Future<void> _pumpReview(
  WidgetTester tester,
  SalesOrderFinanceReview review,
) async {
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
        salesOrderFinanceConfirmationCountProvider.overrideWith(
          (ref) async => 0,
        ),
        salesOrderFinanceConfirmationRepositoryProvider.overrideWithValue(
          _FakeConfirmationRepository([], reviewValue: review),
        ),
      ],
      child: MaterialApp(home: FinanceSalesOrderReviewPage(id: review.orderId)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
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
    expect(find.text('客户应收（本币）'), findsOneWidget);

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
    expect(find.text('已选 0 笔'), findsOneWidget);
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

    expect(find.textContaining('等待销售受控修订并重新审核'), findsOneWidget);
    expect(find.byKey(const Key('finance-review-confirm')), findsNothing);
    expect(find.byKey(const Key('finance-review-reject')), findsNothing);
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
}
