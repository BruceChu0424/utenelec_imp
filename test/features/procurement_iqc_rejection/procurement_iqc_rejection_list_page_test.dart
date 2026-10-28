import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/models/procurement_iqc_rejection.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/pages/procurement_iqc_rejection_list_page.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/repositories/procurement_iqc_rejection_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets(
    'ordinary header queries reach both list and badge counts before pagination',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = _Gateway(items: [_case()]);
      await tester.pumpWidget(
        _app(gateway, permissions: {Perm.procurementIqcRejectionAmountView}),
      );
      await tester.pumpAndSettle();
      final goods = find.byKey(
        const ValueKey('master-column-filter-goodsName'),
      );
      await tester.ensureVisible(goods);
      await tester.tap(goods);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '螺丝_%',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(gateway.filters.last.columnSearch['search.goodsName'], '螺丝_%');
      expect(
        gateway.countFilters.last.columnSearch['search.goodsName'],
        '螺丝_%',
      );
      expect(gateway.filters.last.page, 1);
      final amount = find.byKey(const ValueKey('master-column-filter-amount'));
      await tester.ensureVisible(amount);
      await tester.tap(amount);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '>=25.0001',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(gateway.filters.last.columnSearch['search.amount'], '>=25.0001');
      expect(
        gateway.countFilters.last.columnSearch['search.amount'],
        '>=25.0001',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'server-masked amounts do not acquire query or sorting controls',
    (tester) async {
      await _pumpMaskedHeader(tester);
      final table = tester
          .widget<MasterDataTableView<ProcurementIqcRejectionCase>>(
            find.byKey(const Key('iqc-rejection-task-table')),
          );
      final amount = table.columns.singleWhere(
        (column) => column.key == 'amount',
      );
      expect(amount.sortable, isFalse);
      expect(amount.columnSearchEnabled, isFalse);
      expect(table.serverColumnSearchKeys, isNot(contains('amount')));
      expect(amount.exactValueOf!(table.items.single), isNull);
    },
  );

  testWidgets('header filters send status and receiptType to gateway', (
    tester,
  ) async {
    // 表头筛选生效冒烟：状态/来源固定枚举桶选桶后，repository.list 的既有
    // status / receiptType 参数收到对应值，并重拉回第 1 页。
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = _Gateway(items: [_case()]);
    await tester.pumpWidget(_app(gateway));
    await tester.pumpAndSettle();

    final table = tester
        .widget<MasterDataTableView<ProcurementIqcRejectionCase>>(
          find.byKey(const Key('iqc-rejection-task-table')),
        );
    expect(table.facets.keys, containsAll(<String>['receiptType', 'status']));
    expect(
      table.facets['receiptType']?.map((bucket) => bucket.value),
      containsAll(<String>['PURCHASE', 'SUBCONTRACT']),
    );
    expect(
      table.facets['status']?.map((bucket) => bucket.value),
      containsAll(<String>['PENDING_RETURN', 'TERMINAL']),
    );

    table.onFilterChanged('status', 'PENDING_RETURN');
    await tester.pumpAndSettle();
    expect(gateway.filters.last.status, 'PENDING_RETURN');
    expect(gateway.filters.last.page, 1);

    final refreshed = tester
        .widget<MasterDataTableView<ProcurementIqcRejectionCase>>(
          find.byKey(const Key('iqc-rejection-task-table')),
        );
    refreshed.onFilterChanged('receiptType', 'SUBCONTRACT');
    await tester.pumpAndSettle();
    expect(
      gateway.filters.last.receiptType,
      ProcurementIqcReceiptType.subcontract,
    );
    expect(gateway.filters.last.status, 'PENDING_RETURN');
    await tester.tap(find.text('历史单据'));
    await tester.pumpAndSettle();
    expect(gateway.filters.last.status, 'TERMINAL');
    final historyTable = tester
        .widget<MasterDataTableView<ProcurementIqcRejectionCase>>(
          find.byKey(const Key('iqc-rejection-task-table')),
        );
    historyTable.onFilterChanged('status', null);
    await tester.pumpAndSettle();
    expect(gateway.filters.last.status, 'TERMINAL', reason: '清除历史状态保持历史父类');
    await tester.tap(find.text('待办与进行中'));
    await tester.pumpAndSettle();
    expect(gateway.filters.last.status, 'ACTIVE');
    expect(
      gateway.filters.every((filter) => filter.status != null),
      isTrue,
      reason: '普通列表不发无约束全状态请求',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('375dp uses task cards and preserves server amount masking', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = _Gateway(
      items: [
        _case(masked: true),
        _case(id: 'case-2'),
      ],
    );
    await tester.pumpWidget(_app(gateway));
    await tester.pumpAndSettle();

    // 2026-09-29「大小屏共用一张表」：窄屏由表格内建卡片形态接管，统一挂
    // 表格 key；compact-list 键退役。行数据来自红段（待退回）自动选中的首笔
    // 列表请求（ADR-184 计数带可动手口径）。
    expect(find.byKey(const Key('iqc-rejection-compact-list')), findsNothing);
    expect(find.byKey(const Key('iqc-rejection-task-table')), findsOneWidget);
    // 通用卡片明细按列名渲染（2026-09-29 共用表）：掩码行金额 ***，
    // 未掩码行 25.00——服务端金额掩码在卡片形态同样生效（ADR-128 本币口径）。
    expect(find.textContaining('***', findRichText: true), findsOneWidget);
    expect(find.textContaining('25.00', findRichText: true), findsOneWidget);
    expect(find.textContaining('财务投影异常'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  for (final scenario in const [
    (size: Size(768, 1000), compact: true),
    (size: Size(1440, 900), compact: false),
  ]) {
    testWidgets(
      '${scenario.size.width.toInt()}dp chooses the intended layout',
      (tester) async {
        tester.view.physicalSize = scenario.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(_app(_Gateway(items: [_case()])));
        await tester.pumpAndSettle();

        // 2026-09-29「大小屏共用一张表」：表格组件常驻（compact 由其内建
        // 卡片形态渲染，同一把 key）；不再有独立 compact-list 键。
        expect(
          find.byKey(const Key('iqc-rejection-compact-list')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('iqc-rejection-task-table')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    '1024dp renders high-density table and applies type/status filters',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final requests = <RequestOptions>[];
      final gateway = _filterRepository(requests);
      await tester.pumpWidget(_app(gateway));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('iqc-rejection-task-table')), findsOneWidget);
      MasterDataTableView<ProcurementIqcRejectionCase> table() =>
          tester.widget(find.byKey(const Key('iqc-rejection-task-table')));
      expect(find.byKey(const Key('iqc-rejection-type-filter')), findsNothing);
      expect(
        find.byKey(const Key('iqc-rejection-status-filter')),
        findsNothing,
      );
      table().onFilterChanged('receiptType', 'SUBCONTRACT');
      await tester.pumpAndSettle();
      table().onFilterChanged('status', 'FINANCE_EXCEPTION');
      await tester.pumpAndSettle();
      final lists = requests
          .where((request) => request.path == '/procurement/iqc-rejections')
          .toList();
      // 首笔列表请求由红段（财务异常）自动选中触发且带状态约束——不发无约束
      // 全状态请求；再挑来源是第二笔，重复选同状态不再发请求。
      expect(lists, hasLength(2), reason: '未选择分类不再先拉全量终态记录');
      expect(lists.last.method, 'GET');
      expect(lists.last.uri.queryParameters, {
        'receiptType': 'SUBCONTRACT',
        'status': 'FINANCE_EXCEPTION',
        'page': '1',
        'size': '50',
      });
      expect(find.textContaining('G-001'), findsWidgets);
      table().onFilterChanged('receiptType', null);
      await tester.pumpAndSettle();
      expect(
        requests
            .lastWhere(
              (request) => request.path == '/procurement/iqc-rejections',
            )
            .uri
            .queryParameters['receiptType'],
        isNull,
      );
      // 本页只发列表与计数两种 GET（原拦截器内联断言改为对记录事后断言）。
      expect(
        requests.map((request) => '${request.method} ${request.path}'),
        everyElement(
          anyOf(
            'GET /procurement/iqc-rejections',
            'GET /procurement/iqc-rejections/counts',
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('first-load error offers recovery and succeeds on retry', (
    tester,
  ) async {
    final gateway = _Gateway(items: [_case()], failFirst: true);
    await tester.pumpWidget(_app(gateway));
    await tester.pumpAndSettle();

    // 计数带红段（actionablePendingReturn>0）→ 进页面自动选中「待退回」并发
    // 第一笔列表请求；首笔失败进入恢复态。
    expect(gateway.calls, 1, reason: '首笔列表请求由红段自动选中触发');
    expect(gateway.filters.last.status, 'PENDING_RETURN');
    expect(find.text('无法加载 IQC 不合格任务'), findsOneWidget);
    expect(find.text('重新加载'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(find.text('无法加载 IQC 不合格任务'), findsNothing);
    expect(find.textContaining('G-001'), findsWidgets);
  });

  testWidgets('late search response cannot overwrite the newest keyword', (
    tester,
  ) async {
    final gateway = _RaceGateway();
    await tester.pumpWidget(_app(gateway));
    await tester.pumpAndSettle();
    // 初始行来自红段（待退回）自动选中的首笔列表请求；之后再比赛关键词响应。
    final input = find.descendant(
      of: find.byKey(const Key('iqc-rejection-search')),
      matching: find.byType(TextField),
    );

    await tester.enterText(input, 'old');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.enterText(input, 'new');
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.textContaining('最新货品'), findsWidgets);

    gateway.completeOld();
    await tester.pumpAndSettle();
    expect(find.textContaining('最新货品'), findsWidgets);
    expect(find.textContaining('旧响应货品'), findsNothing);
  });
}

Future<void> _pumpMaskedHeader(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1800, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _app(
      _Gateway(items: [_case(masked: true)]),
      permissions: {Perm.procurementIqcRejectionAmountView},
    ),
  );
  await tester.pumpAndSettle();
}

Widget _app(
  ProcurementIqcRejectionGateway gateway, {
  Set<String> permissions = const {},
}) => ProviderScope(
  overrides: [
    currentPermissionsProvider.overrideWithValue(permissions),
    isSuperAdminProvider.overrideWithValue(false),
  ],
  child: MaterialApp(
    home: ProcurementIqcRejectionListPage(repository: gateway),
  ),
);

class _Gateway implements ProcurementIqcRejectionGateway {
  _Gateway({required this.items, this.failFirst = false});

  final List<ProcurementIqcRejectionCase> items;
  final bool failFirst;
  final List<ProcurementIqcRejectionFilter> filters = [];
  final List<ProcurementIqcRejectionFilter> countFilters = [];
  int calls = 0;

  @override
  Future<ProcurementIqcCreditPreview> previewCredit(
    String id,
    ProcurementIqcConfirmCreditCommand command,
  ) => throw UnimplementedError();
  @override
  Future<PagedResult<ProcurementIqcRejectionCase>> list(
    ProcurementIqcRejectionFilter filter,
  ) async {
    filters.add(filter);
    calls++;
    if (failFirst && calls == 1) throw ApiException('NETWORK', '网络暂不可用');
    return PagedResult(
      items: items,
      page: filter.page,
      size: filter.size,
      total: items.length,
      totalPages: 1,
    );
  }

  @override
  Future<ProcurementIqcRejectionCounts> counts(
    ProcurementIqcRejectionFilter filter,
  ) async {
    countFilters.add(filter);
    return const ProcurementIqcRejectionCounts(
      total: 2,
      pendingReturn: 1,
      returnRecorded: 0,
      creditConfirmed: 0,
      closedNoCredit: 0,
      financeException: 1,
      reversed: 0,
      // ADR-184：服务端另发本人可动手口径；>0 时「待退回」分段挂红徽章，
      // 进页面自动选中该段并发第一笔列表请求（autoSelectBadge 口径）。
      actionablePendingReturn: 1,
      actionableFinanceException: 1,
    );
  }

  @override
  Future<ProcurementIqcRejectionDetail> detail(String id) =>
      throw UnimplementedError();
  @override
  Future<ProcurementIqcRejectionDetail> closeNoCredit(
    String id,
    ProcurementIqcReasonCommand command,
  ) => throw UnimplementedError();
  @override
  Future<ProcurementIqcRejectionDetail> confirmCredit(
    String id,
    ProcurementIqcConfirmCreditCommand command,
  ) => throw UnimplementedError();
  @override
  Future<ProcurementIqcRejectionDetail> recordReturn(
    String id,
    ProcurementIqcRecordReturnCommand command,
  ) => throw UnimplementedError();
  @override
  Future<ProcurementIqcRejectionDetail> retryFinanceProjection(
    String id,
    ProcurementIqcReasonCommand command,
  ) => throw UnimplementedError();
  @override
  Future<ProcurementIqcRejectionDetail> reverse(
    String id,
    ProcurementIqcReasonCommand command,
  ) => throw UnimplementedError();
}

class _RaceGateway extends _Gateway {
  _RaceGateway() : super(items: [_case(goodsName: '初始货品')]);

  final _old = Completer<PagedResult<ProcurementIqcRejectionCase>>();

  void completeOld() => _old.complete(
    PagedResult(
      items: [_case(goodsName: '旧响应货品')],
      page: 1,
      size: 50,
      total: 1,
      totalPages: 1,
    ),
  );

  @override
  Future<PagedResult<ProcurementIqcRejectionCase>> list(
    ProcurementIqcRejectionFilter filter,
  ) {
    filters.add(filter);
    if (filter.keyword == 'old') return _old.future;
    if (filter.keyword == 'new') {
      return Future.value(
        PagedResult(
          items: [_case(goodsName: '最新货品')],
          page: 1,
          size: 50,
          total: 1,
          totalPages: 1,
        ),
      );
    }
    return super.list(filter);
  }
}

ProcurementIqcRejectionCase _case({
  String id = 'case-1',
  String goodsName = '轴套',
  bool masked = false,
}) => ProcurementIqcRejectionCase(
  id: id,
  receiptType: ProcurementIqcReceiptType.purchase,
  receiptBillNo: 'PR-001',
  orderBillNo: 'PO-001',
  supplierName: '供应商A',
  goodsCode: 'G-001',
  goodsName: goodsName,
  failedQty: '5',
  unitName: '件',
  failedAmountLocal: '25.0000',
  currencyCode: 'CNY',
  status: ProcurementIqcRejectionStatus.financeException,
  version: 3,
  allowedActions: const {},
  priceMasked: masked,
  financeExceptionMessage: '财务投影需要修复',
);

ProcurementIqcRejectionRepository _filterRepository(
  List<RequestOptions> requests,
) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        // 只记录请求，不在拦截器里 expect：expect 是被守卫的测试函数，在 Dio
        // 回调里同步触发会抛「Guarded function conflict」，把请求打断成本页
        // NETWORK 错误态；方法/路径断言移到泵完后对这份记录进行。
        requests.add(request);
        final data = request.path.endsWith('/counts')
            ? <String, dynamic>{
                'total': 1,
                'financeException': 1,
                // ADR-184 可动手口径：财务异常红段进页面自动选中并发首笔列表请求。
                'actionableFinanceException': 1,
              }
            : <String, dynamic>{
                'items': [
                  <String, dynamic>{
                    'id': 'case-1',
                    'receiptType': 'PURCHASE',
                    'receiptBillNo': 'PR-001',
                    'orderBillNo': 'PO-001',
                    'goodsCode': 'G-001',
                    'goodsName': '轴套',
                    'failedQty': '5',
                    'status': 'FINANCE_EXCEPTION',
                    'version': 3,
                    'allowedActions': <String>[],
                    'priceMasked': false,
                  },
                ],
                'page': 1,
                'size': 50,
                'total': 1,
                'totalPages': 1,
              };
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  return ProcurementIqcRejectionRepository(ApiClient(dio));
}
