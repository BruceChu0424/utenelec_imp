// 采购编辑页「商业条款快照」契约。
//
// 一张采购单交出去的不只是货和量：供应商 / 结账方式 / 币种 / 汇率 / 税率 是一整套
// 商业条款，必须整套摆在人眼前让他核对，提交时整套校验、整套写进请求体。少一项，
// 单据落地后就没人说得清这批货按什么价、什么汇率、什么税、什么账期结。
//
// 本文件两层断言，守的是同一条契约：
//  1) 行为层(首选)：pump 编辑页，断言这套字段真的渲染出来、必填的标必填、
//     不该有商业条款的单据(申请)一个都不给。控件换皮(DropdownButtonFormField
//     → UtenDropdownField)不影响这层。
//  2) 源码文本层(兜底)：提交前校验与请求体口径没有 widget 出口——要走完提交得先
//     造货品明细行，代价过大——只能把源码当文本读。**重构这段代码时必须同步改下面
//     的锚点**。断言前把空白归一化：换行/缩进变了不会假红，但「谁绑谁」改了会真红。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
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

  test(
    'purchase editor validates and submits the reviewed commercial snapshot',
    () {
      // 行尾归一化：源码可能被 IDE 以 CRLF 保存(2026-09-12 实遇)，断言按 LF 写。
      // 再把连续空白压成单空格：断言只钉「谁绑谁」，不钉排版缩进(2026-09-16 实遇：
      // 商业条款区被多包了一层，缩进从 38 列变 42 列，整条断言假红)。
      final source = File(
        'lib/features/purchase/pages/purchase_doc_edit_page.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final flat = source.replaceAll(RegExp(r'\s+'), ' ');

      // 提交前逐项校验：币种必选、汇率为正、税率落在 0..100。
      expect(source, contains("context.appError('请选择币种')"));
      expect(source, contains("context.appError('汇率必须大于 0')"));
      expect(source, contains("context.appError('请选择结账方式')"));
      expect(
        flat,
        contains('parsedTax == null || parsedTax < 0 || parsedTax > 100'),
      );

      // 请求体：整套条款随单提交，本币金额按表头汇率就地折算。
      expect(flat, contains("'currencyId': _currencyId"));
      expect(flat, contains("'exchangeRate': exchangeRate"));
      expect(flat, contains("'taxRate': taxRate"));
      expect(flat, contains("'settlementMethodId': _settlementMethodId"));
      expect(flat, contains("'amountLocal': qty * price * exchangeRate"));

      // 表单绑定：币种下拉取币种字典、回写 _currencyId(即上面提交的那个字段)。
      expect(flat, contains("'币种', _currencyId, names.currencyEntries"));
      expect(source, contains("labelText: '税率(%)'"));
    },
  );
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
