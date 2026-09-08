import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/models/procurement_iqc_rejection.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/pages/procurement_iqc_rejection_list_page.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/repositories/procurement_iqc_rejection_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
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

    expect(find.byKey(const Key('iqc-rejection-compact-list')), findsOneWidget);
    expect(find.byKey(const Key('iqc-rejection-task-table')), findsNothing);
    expect(find.textContaining('金额 ***'), findsOneWidget);
    expect(find.textContaining('金额 CNY 25.0000'), findsOneWidget);
    expect(find.text('财务投影异常'), findsWidgets);
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

        expect(
          find.byKey(const Key('iqc-rejection-compact-list')),
          scenario.compact ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(const Key('iqc-rejection-task-table')),
          scenario.compact ? findsNothing : findsOneWidget,
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
      final gateway = _Gateway(items: [_case()]);
      await tester.pumpWidget(_app(gateway));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('iqc-rejection-task-table')), findsOneWidget);
      await tester.tap(find.byKey(const Key('iqc-rejection-type-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('委外').last);
      await tester.pumpAndSettle();
      expect(
        gateway.filters.last.receiptType,
        ProcurementIqcReceiptType.subcontract,
      );

      await tester.tap(find.byKey(const Key('iqc-rejection-status-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('财务投影异常').last);
      await tester.pumpAndSettle();
      expect(gateway.filters.last.status, 'FINANCE_EXCEPTION');
    },
  );

  testWidgets('first-load error offers recovery and succeeds on retry', (
    tester,
  ) async {
    final gateway = _Gateway(items: [_case()], failFirst: true);
    await tester.pumpWidget(_app(gateway));
    await tester.pumpAndSettle();

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

Widget _app(ProcurementIqcRejectionGateway gateway) => ProviderScope(
  child: MaterialApp(
    home: ProcurementIqcRejectionListPage(repository: gateway),
  ),
);

class _Gateway implements ProcurementIqcRejectionGateway {
  _Gateway({required this.items, this.failFirst = false});

  final List<ProcurementIqcRejectionCase> items;
  final bool failFirst;
  final List<ProcurementIqcRejectionFilter> filters = [];
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
  ) async => const ProcurementIqcRejectionCounts(
    total: 2,
    pendingReturn: 1,
    returnRecorded: 0,
    creditConfirmed: 0,
    closedNoCredit: 0,
    financeException: 1,
    reversed: 0,
  );

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
