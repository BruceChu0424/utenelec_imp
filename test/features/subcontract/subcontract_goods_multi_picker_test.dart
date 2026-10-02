import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_goods_picker.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_edit_page.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_order_edit_page.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_goods_picker.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';
import 'package:uten_imp/shared/models/procurement_commercial_terms.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../../support/document_scope_capability_overrides.dart';

const _goods = [
  GoodsListItem(
    id: 'g1',
    code: 'G1',
    name: '第一件',
    colorId: 'red',
    unitId: 'piece',
    stockPlace: 'A1',
  ),
  GoodsListItem(
    id: 'g2',
    code: 'G2',
    name: '第二件',
    colorId: 'blue',
    unitId: 'kg',
    stockPlace: 'B2',
  ),
];

void main() {
  testWidgets('委外订货一次带入多件并全选，逐件主档条款和默认价格保持有效', (tester) async {
    final api = _Api();
    final terms = _Terms(api);
    UtenGoodsPickerScope? requestedScope;
    await _pump(tester, const SubcontractOrderEditPage(), api, (
      _,
      _,
      scope,
    ) async {
      requestedScope = scope;
      return _goods;
    }, terms: terms);
    final grid = _grid(tester).controller;
    grid.rows.single.qty.text = '7';
    await tester.tap(
      find
          .descendant(
            of: find.byType(UtenEditableGrid<SubcontractGridRow>),
            matching: find.text('点击选择'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(requestedScope, UtenGoodsPickerScope.sellable);
    expect(grid.rows.map((row) => row.goods?.id), ['g1', 'g2']);
    expect(grid.selectedRows, containsAll(grid.rows));
    expect(grid.rows.first.qty.text, '7');
    expect(grid.rows.last.qty.text, isEmpty);
    expect(grid.rows.map((row) => row.unitId), ['piece', 'kg']);
    expect(grid.rows.map((row) => row.colorId), ['red', 'blue']);
    expect(grid.rows.map((row) => row.stockPlaceNotifier.value), ['A1', 'B2']);
    expect(grid.rows.map((row) => row.price.text), ['2.5', '4']);
    expect(
      grid.rows.every((row) => row.upstreamItemId == null && !row.sourceLocked),
      isTrue,
    );
    expect(terms.requested, containsAll(['g1', 'g2']));
    expect(tester.takeException(), isNull);
  });

  for (final type in [
    SubcontractDocType.inquiry,
    SubcontractDocType.materialIssue,
  ]) {
    testWidgets('${type.name}多选保留选择范围和手填金额，新增行不捏造上游来源', (tester) async {
      UtenGoodsPickerScope? requestedScope;
      await _pump(tester, SubcontractDocEditPage(docType: type), _Api(), (
        _,
        _,
        scope,
      ) async {
        requestedScope = scope;
        return _goods;
      });
      final grid = _grid(tester).controller;
      grid.rows.single.qty.text = '5';
      grid.rows.single.price.text = '8';
      await tester.tap(
        find
            .descendant(
              of: find.byType(UtenEditableGrid<SubcontractGridRow>),
              matching: find.text('点击选择'),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(
        requestedScope,
        type == SubcontractDocType.materialIssue
            ? UtenGoodsPickerScope.material
            : UtenGoodsPickerScope.sellable,
      );
      expect(grid.rows.map((row) => row.goods?.id), ['g1', 'g2']);
      expect(grid.rows.first.qty.text, '5');
      expect(grid.rows.first.price.text, '8');
      expect(grid.rows.last.price.text, isEmpty);
      expect(
        grid.rows.every(
          (row) => row.upstreamItemId == null && row.upstreamItemIds.isEmpty,
        ),
        isTrue,
      );
      expect(grid.rows.map((row) => row.unitRate), [1, 1]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('取消选择不清空当前行', (tester) async {
    await _pump(
      tester,
      const SubcontractOrderEditPage(),
      _Api(),
      (_, _, _) async => [],
    );
    final grid = _grid(tester).controller;
    final row = grid.rows.single..qty.text = '6';
    await tester.tap(
      find
          .descendant(
            of: find.byType(UtenEditableGrid<SubcontractGridRow>),
            matching: find.text('点击选择'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(grid.rows, [row]);
    expect(row.qty.text, '6');
    expect(row.goods, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('来自上游的锁定行不能通过多选改换货品', (tester) async {
    var pickerCalls = 0;
    await _pump(tester, const SubcontractOrderEditPage(), _Api(), (
      _,
      _,
      _,
    ) async {
      pickerCalls++;
      return _goods;
    });
    final controller = _grid(tester).controller;
    final source = SubcontractGridRow(sourceLocked: true)
      ..goods = const GoodsOption(id: 'source', name: '来源件')
      ..upstreamItemId = 'application-item'
      ..unitId = 'piece'
      ..qty.text = '9';
    controller.replaceAll([source]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('来源件'));
    await tester.pumpAndSettle();
    expect(pickerCalls, 0);
    expect(controller.rows.single.goods?.id, 'source');
    expect(controller.rows.single.upstreamItemId, 'application-item');
    expect(tester.takeException(), isNull);
  });
}

UtenEditableGrid<SubcontractGridRow> _grid(WidgetTester tester) =>
    tester.widget(find.byType(UtenEditableGrid<SubcontractGridRow>));

Future<void> _pump(
  WidgetTester tester,
  Widget page,
  _Api api,
  SubcontractGridGoodsPicker picker, {
  _Terms? terms,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        sessionProvider.overrideWith(_EmptySession.new),
        subcontractWriteAllDocumentScope(),
        subcontractGridGoodsPickerProvider.overrideWithValue(picker),
        if (terms != null)
          subcontractRepositoryProvider(
            SubcontractDocType.order,
          ).overrideWithValue(terms),
      ],
      child: MaterialApp(home: page),
    ),
  );
  await tester.pumpAndSettle();
}

class _EmptySession extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {
    'items': <Map<String, dynamic>>[],
    'page': 1,
    'size': 20,
    'total': 0,
    'totalPages': 0,
  };
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('suppliers')) {
      return [
        {'id': 'sup', 'code': 'SUP', 'name': '委外商', 'status': '使用'},
      ];
    }
    if (path.contains('currencies')) {
      return [
        {'id': 'cny', 'code': 'CNY', 'name': '人民币', 'status': '使用'},
      ];
    }
    if (path.contains('units')) {
      return [
        {'id': 'piece', 'name': '个', 'status': '使用'},
        {'id': 'kg', 'name': '千克', 'status': '使用'},
      ];
    }
    if (path.contains('settlement')) {
      return [
        {'id': 'monthly', 'code': 'MONTH', 'name': '月结', 'status': '使用'},
      ];
    }
    return [];
  }
}

class _Terms extends SubcontractRepository {
  _Terms(ApiClient api) : super(api, SubcontractDocType.order);
  final requested = <String>{};
  @override
  Future<Map<String, ProcurementLastTerms>> lastTermsByGoods(
    Iterable<String> goodsIds,
  ) async {
    requested.addAll(goodsIds);
    return {
      for (final g in _goods)
        g.id: ProcurementLastTerms(
          supplierId: 'sup',
          settlementMethodId: 'monthly',
          currencyId: 'cny',
          exchangeRate: 1,
          taxRate: 0,
          subcontractPrice: g.id == 'g1' ? 2.5 : 4,
          priceContext: ProcurementPriceContext(
            supplierId: 'sup',
            colorId: g.colorId,
            unitId: g.unitId,
            currencyId: 'cny',
            taxRate: 0,
          ),
        ),
    };
  }
}
