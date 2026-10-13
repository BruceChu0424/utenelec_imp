// 采购编辑页「商业条款快照」契约。
//
// 一张采购单交出去的不只是货和量：供应商 / 结账方式 / 币种 / 汇率 / 税率 是一整套
// 商业条款，必须整套摆在人眼前让他核对，提交时整套校验、整套写进请求体。少一项，
// 单据落地后就没人说得清这批货按什么价、什么汇率、什么税、什么账期结。
//
// 本文件核对真实表头字段与必填口径。来源条款的只读、精确文本、草稿恢复及
// 服务端派生请求体由 procurement_source_form_test.dart 的实际保存行为覆盖。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_supplier_picker.dart';
import 'package:uten_imp/features/purchase/config/purchase_doc_config.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_edit_page.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

/// 带商业条款的三张单据(申请单是计划下达的需求，没有商业事实)。
///
/// order 留在表里是守 settlementRequired/supplierRequired 都为 true 的那条配置分支
/// (唯一一张结账方式必填的单)；真实路由上订货单已走 PurchaseOrderEditPage 的
/// 行级条款(每行一供应商/汇率/税率)，那套快照不在本文件覆盖范围内。
const _commercialDocTypes = <PurchaseDocType>[
  PurchaseDocType.order,
  PurchaseDocType.receipt,
  PurchaseDocType.returnDoc,
];

void main() {
  for (final docType in _commercialDocTypes) {
    testWidgets('${docType.name} editor shows the whole commercial snapshot', (
      tester,
    ) async {
      await _pumpEditor(tester, docType);
      final cfg = PurchaseDocConfig.by(docType);

      // 供应商 = 结算对象，三张单据都必填。
      final supplierFinder = find.byType(SupplierPickerField);
      expect(supplierFinder, findsOneWidget);
      final supplier = tester.widget<SupplierPickerField>(supplierFinder);
      expect(supplier.label, '供应商');
      expect(supplier.required, cfg.supplierRequired);

      // 币种 / 汇率 / 税率 = 金额口径三件套，缺一项本币金额就没法复算。
      final currency = _dropdownField(tester, '币种');
      expect(currency.required, isTrue, reason: '币种是本币换算的锚，不能可空');
      expect(find.widgetWithText(TextField, '汇率'), findsOneWidget);
      expect(find.widgetWithText(TextField, '税率(%)'), findsOneWidget);

      // 结账方式 = 账期口径；订货单必填(下单即定账期)，收货/退货沿用来源快照。
      final settlement = _dropdownField(tester, '结账方式');
      expect(settlement.required, cfg.settlementRequired);
      expect(settlement.allowClear, !cfg.settlementRequired);
    });
  }

  testWidgets('purchase request editor carries no commercial snapshot', (
    tester,
  ) async {
    await _pumpEditor(tester, PurchaseDocType.request);

    // 计划下达的采购申请只讲需求，不讲钱：整套商业条款一个都不该出现。
    expect(_dropdownFinder('币种'), findsNothing);
    expect(_dropdownFinder('结账方式'), findsNothing);
    expect(find.widgetWithText(TextField, '汇率'), findsNothing);
    expect(find.widgetWithText(TextField, '税率(%)'), findsNothing);
  });
}

Finder _dropdownFinder(String label) => find.byWidgetPredicate(
  (widget) => widget is UtenDropdownField && widget.label == label,
);

UtenDropdownField _dropdownField(WidgetTester tester, String label) {
  final finder = _dropdownFinder(label);
  expect(finder, findsOneWidget, reason: '商业条款字段「$label」必须渲染');
  return tester.widget<UtenDropdownField>(finder);
}

Future<void> _pumpEditor(WidgetTester tester, PurchaseDocType docType) async {
  tester.view.physicalSize = const Size(1600, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
        apiClientProvider.overrideWithValue(_EmptyApi()),
        sessionProvider.overrideWith(_EmptySessionNotifier.new),
      ],
      child: MaterialApp(home: PurchaseDocEditPage(docType: docType)),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

class _EmptySessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

/// 字典/列表一律返空：本文件只关心表头商业条款字段在不在、必不必填。
class _EmptyApi extends ApiClient {
  _EmptyApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {
    'items': <Map<String, dynamic>>[],
    'page': 1,
    'size': 1,
    'total': 0,
    'totalPages': 0,
  };

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}
