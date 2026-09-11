// 销售单据详情页 2026-09-11 折叠头改版回归：
// 「先滚页面收头部（表头卡/预收/出货卡/附件）、再滚明细表内部」+ 三视口叠 textScale 1.5 不溢出。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_detail_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

import '../../../support/collapsing_header_harness.dart';

class _DetailApi extends ApiClient {
  _DetailApi(this.detail) : super(Dio());

  final Map<String, dynamic> detail;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => detail;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const <Map<String, dynamic>>[];
}

Map<String, dynamic> _orderDetail() => <String, dynamic>{
  'id': 'order-collapse',
  'billNo': 'SO-2026-001',
  'billDate': '2026-09-11',
  'makerName': '销售甲',
  'createdAt': '2026-09-11T09:00:00+08:00',
  'status': 0,
  'writable': true,
  'remark': '折叠头回归用订单',
  'items': <Map<String, dynamic>>[
    for (var i = 0; i < 20; i++)
      <String, dynamic>{
        'id': 'line-$i',
        'qty': i + 1,
        'price': 10,
        'amountOriginal': (i + 1) * 10,
      },
  ],
};

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  double textScale = 1.0,
}) async {
  useUtenViewport(tester, size);
  final api = _DetailApi(_orderDetail());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(api),
        ),
        currentPermissionsProvider.overrideWithValue(const <String>{
          Perm.salesOrderView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        builder: utenTextScaleBuilder(textScale),
        home: const SalesDocDetailPage(
          docType: SalesDocType.order,
          id: 'order-collapse',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('销售订单详情：上滚先收表头卡，明细表接着内滚', (tester) async {
    await _pump(tester, size: const Size(1280, 900));

    expect(find.byType(UtenCollapsingHeaderScrollView), findsOneWidget);
    expect(find.text('明细 (20)'), findsOneWidget);
    await expectUtenHeaderCollapses(
      tester,
      headerAnchor: find.text('单据号'),
      bodyAnchor: find.byType(MasterDataTableView<SalesDocItem>),
    );
    // 明细标题行是 body 里表格的兄弟：头部收起后仍钉在 body 顶。
    expect(find.text('明细 (20)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final viewport in utenCollapsingViewports) {
    testWidgets('销售订单详情 ${viewport.label} · textScale 1.5 不溢出', (tester) async {
      await _pump(tester, size: viewport.size, textScale: 1.5);
      await expectUtenBodyReachable(
        tester,
        bodyAnchor: find.byType(MasterDataTableView<SalesDocItem>),
      );
    });
  }
}
