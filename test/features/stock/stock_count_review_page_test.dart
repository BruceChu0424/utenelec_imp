import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/models/goods_issue_method.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_issue_method_repository.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/features/stock/counts/models/stock_count_request.dart';
import 'package:uten_imp/features/stock/counts/pages/stock_count_review_page.dart';
import 'package:uten_imp/features/stock/counts/repositories/stock_count_request_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

class _Repo implements StockCountRequestRepository {
  _Repo({this.stale = false, this.setupBasis});
  final bool stale;
  final String? setupBasis;
  final List<String> actions = const ['APPROVE', 'REJECT'];
  int reads = 0;
  int approvals = 0;
  String? reviewedReason;
  StockCountRequest get request => StockCountRequest(
    id: 'count-1',
    requestNo: 'PD01',
    warehouseId: 'w',
    warehouseName: '原料仓',
    reviewRoute: 'FINANCE',
    status: 'PENDING',
    version: 7,
    submittedByName: '张三',
    reason: '月末盘点',
    allowedActions: actions,
    lines: [
      StockCountRequestLine(
        goodsId: 'g',
        goodsName: '颗粒',
        unitName: 'kg',
        beforeQty: '9007199254740993.0000',
        targetQty: '9007199254740994.0000',
        deltaQty: '1.0000',
        beforeWeightKg: '8.0000',
        targetWeightKg: '8.0000',
        currentQty: '9007199254740993.0000',
        stale: stale,
        materialSetupBasis: setupBasis,
        goodsVersion: 17,
      ),
    ],
  );
  @override
  Future<StockCountRequest> detail(String id) async {
    reads++;
    return request;
  }

  @override
  Future<PagedResult<StockCountRequest>> list({
    String? reviewRoute,
    String? status,
    int page = 1,
    int size = 50,
  }) async {
    reads++;
    return PagedResult(
      items: [request],
      page: page,
      size: size,
      total: 1,
      totalPages: 1,
    );
  }

  @override
  Future<StockCountRequest> approve(
    String id, {
    required int expectedVersion,
    required String idempotencyKey,
    String? reason,
  }) async {
    expect(expectedVersion, 7);
    expect(idempotencyKey, isNotEmpty);
    approvals++;
    reviewedReason = reason;
    return StockCountRequest(
      id: id,
      requestNo: 'PD01',
      warehouseId: 'w',
      warehouseName: '原料仓',
      reviewRoute: 'FINANCE',
      status: 'APPROVED',
      version: 8,
      lines: request.lines,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Preview implements GoodsIssueMethodRepository {
  _Preview({this.version = 17});
  final int version;
  String? basis;
  @override
  Future<GoodsIssueMethodPreview> preview(
    String goodsId, {
    required String target,
    String? costBasis,
  }) async {
    basis = costBasis;
    return GoodsIssueMethodPreview(
      goodsId: goodsId,
      targetIssueMethod: target,
      targetCostBasis: costBasis,
      version: version,
      bomRows: const [
        GoodsIssueMethodBomRow(productName: '关联注塑件', action: 'REMOVE'),
      ],
    );
  }

  @override
  Future<void> apply(List<GoodsIssueMethodChange> items) async =>
      throw StateError('盘点审核不能单独修改主档');
}

Future<void> _pump(
  WidgetTester tester,
  _Repo repo, {
  Set<String> permissions = const {Perm.stockCountFinanceReview},
  _Preview? preview,
}) async {
  await tester.binding.setSurfaceSize(const Size(2000, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        stockCountRequestRepositoryProvider.overrideWithValue(repo),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        goodsIssueMethodRepositoryProvider.overrideWithValue(
          preview ?? _Preview(),
        ),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: StockCountReviewPage(
          reviewRoute: 'FINANCE',
          requestId: 'count-1',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('未授权不读取审核数据，旧库存权限不能打开审核入口', (tester) async {
    final repo = _Repo();
    await _pump(tester, repo, permissions: {Perm.stockBalanceAdjust});
    expect(repo.reads, 0);
    expect(find.text('未获本页盘点授权'), findsOneWidget);
    expect(find.byKey(const Key('stock-count-approve')), findsNothing);
  });

  testWidgets('只给变更旧数值删除线，未修改重量和整行不染色', (tester) async {
    final repo = _Repo();
    await _pump(tester, repo);
    final old = tester.widget<Text>(find.text('9007199254740993.0000').first);
    expect(old.style?.decoration, TextDecoration.lineThrough);
    expect(find.text('9007199254740994.0000'), findsOneWidget);
    final weight = tester.widget<Text>(find.text('8.0000').first);
    expect(weight.style?.decoration, isNot(TextDecoration.lineThrough));
    final table = tester.widget<MasterDataTableView<StockCountRequestLine>>(
      find.byType(MasterDataTableView<StockCountRequestLine>),
    );
    expect(table.rowColor, isNull);
    expect(
      table.columns.map((c) => c.label),
      containsAll(['原数量', '盘点数量', '数量差额']),
    );
  });

  testWidgets('审核用当前版本提交且成功后撤掉审核按钮', (tester) async {
    final repo = _Repo();
    await _pump(tester, repo);
    await tester.tap(find.byKey(const Key('stock-count-approve')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('stock-count-review-confirm')));
    await tester.pumpAndSettle();
    expect(repo.approvals, 1);
    expect(find.byKey(const Key('stock-count-approve')), findsNothing);
  });

  testWidgets('提交后库存变化不能通过，但允许退回', (tester) async {
    final repo = _Repo(stale: true);
    await _pump(tester, repo);
    expect(find.textContaining('提交后库存已变化'), findsOneWidget);
    await tester.tap(find.byKey(const Key('stock-count-approve')));
    await tester.pump();
    expect(find.byKey(const Key('stock-count-review-confirm')), findsNothing);
    expect(repo.approvals, 0);
    expect(find.byKey(const Key('stock-count-reject')), findsOneWidget);
  });

  testWidgets('数值相同但小数位不同不画删除线', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: StockCountOldValue(before: '1.0000', after: '1'),
      ),
    );
    expect(
      tester.widget<Text>(find.text('1.0000')).style?.decoration,
      isNot(TextDecoration.lineThrough),
    );
  });

  testWidgets('首次材料用途固定为申请值，核对全局影响并确认后才能批准', (tester) async {
    final repo = _Repo(setupBasis: 'SHARED');
    final preview = _Preview();
    await _pump(
      tester,
      repo,
      permissions: {
        Perm.stockCountFinanceReview,
        Perm.goodsEdit,
        Perm.goodsBomEdit,
      },
      preview: preview,
    );
    expect(preview.basis, 'SHARED');
    final dropdown = tester.widget<UtenDropdownField>(
      find.byKey(const ValueKey('wm-first-use-basis-g')),
    );
    expect(dropdown.enabled, isFalse);
    await tester.tap(find.byKey(const Key('stock-count-approve')));
    await tester.pump();
    expect(find.byKey(const Key('stock-count-review-confirm')), findsNothing);
    final confirm = find.byKey(const ValueKey('wm-first-use-confirm-g'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('stock-count-approve')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stock-count-review-confirm')), findsOneWidget);
    expect(repo.approvals, 0, reason: '用途勾选不单独写主档或库存');
  });

  testWidgets('只有盘点审核权而无主档权限不能批准首次材料接入', (tester) async {
    final repo = _Repo(setupBasis: 'OWN');
    await _pump(tester, repo);
    await tester.tap(find.byKey(const Key('stock-count-approve')));
    await tester.pump();
    expect(find.byKey(const Key('stock-count-review-confirm')), findsNothing);
    expect(repo.approvals, 0);
  });

  testWidgets('货品版本变化后不能确认旧申请的用途影响', (tester) async {
    final repo = _Repo(setupBasis: 'OWN');
    await _pump(
      tester,
      repo,
      permissions: {
        Perm.stockCountFinanceReview,
        Perm.goodsEdit,
        Perm.goodsBomEdit,
      },
      preview: _Preview(version: 18),
    );
    final confirm = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('wm-first-use-confirm-g')),
    );
    expect(confirm.onChanged, isNull);
    expect(find.textContaining('申请后货品版本已变化'), findsOneWidget);
  });
}
