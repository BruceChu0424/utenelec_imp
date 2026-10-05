// ADR-143 §二.3：委外订货单明细的委外件缺 BOM(服务端 items[].bomMissing)时，
// 编辑页把这些行标红并提示「缺 BOM，研发完善后才能提交财务」；草稿照常保存。
import '../../support/native_detail_reader_overrides.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/reference_method_option.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_order_edit_page.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart' as mn;

import '../../support/document_scope_capability_overrides.dart';

const _settlementId = '10000000-0000-0000-0000-000000000030';

const _settlementMethod = ReferenceMethodOption(
  id: _settlementId,
  code: 'NET30',
  name: '月结',
  legacyId: 30,
);

Map<String, dynamic> _orderDetailJson({required bool secondLineBomMissing}) => {
  'id': 'order-1',
  'makerId': 'maker-1',
  'billNo': 'WO-2026-001',
  'billDate': '2026-10-04',
  'makerName': '测试员',
  'createdAt': '2026-10-04T10:00:00+08:00',
  'supplierId': 'supplier-1',
  'currencyId': 'currency-cny',
  'taxRate': 13,
  'settlementMethodId': _settlementId,
  'status': 0,
  'canEdit': true,
  'canDelete': true,
  'canReverse': false,
  'totalLocal': 80,
  'items': [
    {'id': 'line-1', 'goodsId': 'goods-1', 'qty': 10, 'price': 5},
    {
      'id': 'line-2',
      'goodsId': 'goods-2',
      'qty': 6,
      'price': 5,
      'bomMissing': secondLineBomMissing,
    },
  ],
};

ApiClient _api() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: <Object?>[],
        ),
      ),
    ),
  );
  return ApiClient(dio);
}

class _RecordingOrderRepository extends SubcontractRepository {
  _RecordingOrderRepository(this.detailValue, ApiClient api)
    : super(api, SubcontractDocType.order);

  final SubcontractDocDetail detailValue;
  Map<String, dynamic>? updatedBody;

  @override
  Future<SubcontractDocDetail> detail(String id) async => detailValue;

  @override
  Future<SubcontractDocDetail> update(
    String id,
    Map<String, dynamic> body,
  ) async {
    updatedBody = Map<String, dynamic>.from(body);
    return detailValue;
  }
}

Future<_RecordingOrderRepository> _pump(
  WidgetTester tester, {
  required bool secondLineBomMissing,
}) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = _api();
  final repository = _RecordingOrderRepository(
    SubcontractDocDetail.fromJson(
      _orderDetailJson(secondLineBomMissing: secondLineBomMissing),
    ),
    api,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeDetailReaderOverrides(),
        subcontractWriteAllDocumentScope(),
        currentPermissionsProvider.overrideWithValue(const <String>{
          Perm.subcontractOrderPriceView,
        }),
        subcontractRepositoryProvider(
          SubcontractDocType.order,
        ).overrideWithValue(repository),
        mn.masterNameServiceProvider.overrideWithValue(
          mn.MasterNameService(api),
        ),
        settlementMethodOptionsProvider.overrideWith(
          (ref) async => const [_settlementMethod],
        ),
      ],
      child: const MaterialApp(home: SubcontractOrderEditPage(id: 'order-1')),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

void main() {
  test('订货明细模型读取 bomMissing，缺省为 false', () {
    final detail = SubcontractDocDetail.fromJson(
      _orderDetailJson(secondLineBomMissing: true),
    );
    expect(detail.items.map((item) => item.bomMissing).toList(), [false, true]);
  });

  testWidgets('缺 BOM 的明细行标红并提示研发完善后才能提交财务，草稿照常保存', (tester) async {
    final repository = await _pump(tester, secondLineBomMissing: true);
    expect(tester.takeException(), isNull);

    expect(
      find.byKey(const Key('subcontract-order-bom-missing-hint')),
      findsOneWidget,
    );
    expect(find.textContaining('第 2 行('), findsOneWidget);
    expect(find.textContaining('第 1 行('), findsNothing);
    expect(find.textContaining('缺 BOM，研发完善后才能提交财务'), findsOneWidget);

    final grid = tester.widget<UtenEditableGrid<SubcontractGridRow>>(
      find.byType(UtenEditableGrid<SubcontractGridRow>),
    );
    final rows = grid.controller.rows;
    expect(grid.rowColor!(rows[0]), isNull);
    expect(grid.rowColor!(rows[1]), isNotNull);

    // 草稿可以保存(提交财务由服务端拒绝并通知研发)。
    await tester.tap(find.text('保存订货单草稿'));
    await tester.pump();
    expect(repository.updatedBody, isNotNull);
  });

  testWidgets('全部委外件都有 BOM 时不显示提示也不标红', (tester) async {
    await _pump(tester, secondLineBomMissing: false);
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('subcontract-order-bom-missing-hint')),
      findsNothing,
    );
    final grid = tester.widget<UtenEditableGrid<SubcontractGridRow>>(
      find.byType(UtenEditableGrid<SubcontractGridRow>),
    );
    for (final row in grid.controller.rows) {
      expect(grid.rowColor!(row), isNull);
    }
  });
}
