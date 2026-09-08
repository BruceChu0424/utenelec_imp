import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/reference_method_option.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_doc_config.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_detail_page.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_order_edit_page.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
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

Map<String, dynamic> _orderDetailJson() => {
  'id': 'order-1',
  'makerId': 'maker-1',
  'billNo': 'WO-2026-001',
  'billDate': '2026-08-22',
  'makerName': '测试员',
  'createdAt': '2026-08-22T10:00:00+08:00',
  'supplierId': 'supplier-1',
  'currencyId': 'currency-cny',
  'taxRate': 13,
  'settlementMethodId': _settlementId,
  'status': 0,
  'canEdit': true,
  'canDelete': true,
  'canReverse': false,
  'totalLocal': 50,
  'items': [
    {'id': 'line-1', 'goodsId': 'goods-1', 'qty': 10, 'price': 5},
  ],
};

ApiClient _api(Object? Function(RequestOptions request) responder) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: responder(request),
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

Widget _app({
  required ApiClient api,
  required SubcontractRepository repository,
  required Override settlementOverride,
  required Widget home,
}) => ProviderScope(
  overrides: [
    subcontractWriteAllDocumentScope(),
    // Settlement terms are part of the commercial detail surface and are
    // intentionally protected by the existing price-view permission.
    currentPermissionsProvider.overrideWithValue(const <String>{
      Perm.subcontractOrderPriceView,
    }),
    subcontractRepositoryProvider(
      SubcontractDocType.order,
    ).overrideWithValue(repository),
    mn.masterNameServiceProvider.overrideWithValue(mn.MasterNameService(api)),
    settlementOverride,
  ],
  child: MaterialApp(home: home),
);

void _usePhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(375, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  test('委外订单配置强制结算方式，进仓兼容可选', () {
    expect(SubcontractDocConfig.order.hasSettlement, isTrue);
    expect(SubcontractDocConfig.order.settlementRequired, isTrue);
    expect(SubcontractDocConfig.receipt.hasSettlement, isTrue);
    expect(SubcontractDocConfig.receipt.settlementRequired, isFalse);
    expect(SubcontractDocConfig.waste.approveEffect, contains('建议索赔金额'));
    expect(SubcontractDocConfig.waste.approveEffect, contains('不自动扣款'));
    expect(SubcontractDocConfig.waste.approveEffect, isNot(contains('立负应付')));
  });

  test('订单列表与详情模型 round-trip settlementMethodId', () {
    final listItem = SubcontractDocListItem.fromJson({
      'id': 'order-1',
      'settlementMethodId': _settlementId,
    });
    final detail = SubcontractDocDetail.fromJson(_orderDetailJson());

    expect(listItem.settlementMethodId, _settlementId);
    expect(detail.settlementMethodId, _settlementId);
  });

  testWidgets('375px 订单详情显示结算方式名称与代码', (tester) async {
    _usePhoneViewport(tester);
    final api = _api((request) {
      if (request.path.contains('/subcontract/orders/order-1')) {
        return _orderDetailJson();
      }
      return <Object?>[];
    });

    await tester.pumpWidget(
      _app(
        api: api,
        repository: SubcontractRepository(api, SubcontractDocType.order),
        settlementOverride: settlementMethodOptionsProvider.overrideWith(
          (ref) async => const [_settlementMethod],
        ),
        home: const SubcontractDocDetailPage(
          docType: SubcontractDocType.order,
          id: 'order-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('结算方式'), findsOneWidget);
    expect(find.text('月结(NET30)'), findsOneWidget);
  });

  testWidgets('375px 编辑加载已有结算方式且提交 settlementMethodId', (tester) async {
    _usePhoneViewport(tester);
    final api = _api(
      (request) => request.path.endsWith('/warehouses/dict')
          ? <Map<String, dynamic>>[
              {'id': 'main', 'name': '总仓'},
              {'id': 'original', 'name': '内部成品仓', 'parentId': 'main'},
              {'id': 'assembly', 'name': '组装仓', 'parentId': 'main'},
            ]
          : <Object?>[],
    );
    final repository = _RecordingOrderRepository(
      SubcontractDocDetail.fromJson(
        _orderDetailJson()..['warehouseId'] = 'original',
      ),
      api,
    );

    await tester.pumpWidget(
      _app(
        api: api,
        repository: repository,
        settlementOverride: settlementMethodOptionsProvider.overrideWith(
          (ref) async => const [_settlementMethod],
        ),
        home: const SubcontractOrderEditPage(id: 'order-1'),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 2026-09 行级商业条款：结算方式在明细行，单元格显示名称(代码)，单头无结算字段。
    expect(find.text('月结(NET30)'), findsOneWidget);

    // The saved preparation warehouse is visible, and employees can choose a real child warehouse.
    await tester.ensureVisible(
      find.byKey(const Key('subcontract-preparation-warehouse')),
    );
    await tester.tap(find.text('内部成品仓'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('组装仓').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存订货单草稿'));
    await tester.pump();

    // 单头条款 = 全行一致的条款；行级同值随行提交（批量拆单契约）。
    expect(repository.updatedBody?['settlementMethodId'], _settlementId);
    expect(repository.updatedBody?['warehouseId'], 'assembly');
    final items = repository.updatedBody?['items'] as List;
    expect((items.first as Map)['settlementMethodId'], _settlementId);
  });

  testWidgets('结算方式未选择时提示红字并阻断保存', (tester) async {
    _usePhoneViewport(tester);
    final api = _api((_) => <Object?>[]);
    final detailJson = _orderDetailJson()..remove('settlementMethodId');
    final repository = _RecordingOrderRepository(
      SubcontractDocDetail.fromJson(detailJson),
      api,
    );

    await tester.pumpWidget(
      _app(
        api: api,
        repository: repository,
        settlementOverride: settlementMethodOptionsProvider.overrideWith(
          (ref) async => const [_settlementMethod],
        ),
        home: const SubcontractOrderEditPage(id: 'order-1'),
      ),
    );
    await tester.pumpAndSettle();

    // 必填且为空：行内下拉格显示红字提示「点击选择」（requiredEmpty 口径）。
    expect(find.text('点击选择'), findsAtLeastNWidgets(1));

    await tester.tap(find.text('保存订货单草稿'));
    await tester.pump();

    // 行级结算方式必填：未选择阻断保存（更新未发出）。
    expect(repository.updatedBody, isNull);
  });

  testWidgets('结算方式空字典阻断保存并提示已停用', (tester) async {
    _usePhoneViewport(tester);
    final api = _api((_) => <Object?>[]);
    final repository = _RecordingOrderRepository(
      SubcontractDocDetail.fromJson(_orderDetailJson()),
      api,
    );

    await tester.pumpWidget(
      _app(
        api: api,
        repository: repository,
        settlementOverride: settlementMethodOptionsProvider.overrideWith(
          (ref) async => const <ReferenceMethodOption>[],
        ),
        home: const SubcontractOrderEditPage(id: 'order-1'),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    await tester.tap(find.text('保存订货单草稿'));
    await tester.pump();

    // 字典为空 = 既有值不在启用字典中：阻断保存（更新未发出）。
    expect(repository.updatedBody, isNull);
  });

  testWidgets('结算方式字典加载失败不崩且阻断保存', (tester) async {
    _usePhoneViewport(tester);
    final api = _api((_) => <Object?>[]);
    final repository = _RecordingOrderRepository(
      SubcontractDocDetail.fromJson(_orderDetailJson()),
      api,
    );

    await tester.pumpWidget(
      _app(
        api: api,
        repository: repository,
        settlementOverride: settlementMethodOptionsProvider.overrideWith(
          (ref) async => throw StateError('dictionary unavailable'),
        ),
        home: const SubcontractOrderEditPage(id: 'order-1'),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('— 不选 —'), findsNothing);

    await tester.tap(find.text('保存订货单草稿'));
    await tester.pump();

    expect(repository.updatedBody, isNull);
  });
}
