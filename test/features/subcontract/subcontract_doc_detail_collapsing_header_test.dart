// 委外单据详情页 2026-09-11 折叠头改版回归：
// 「先滚页面收头部（表头卡/横幅/进度/附件）、再滚明细表内部」+ 三视口叠 textScale 1.5 不溢出。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_detail_page.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart' as mn;

import '../../support/collapsing_header_harness.dart';
import '../../support/document_scope_capability_overrides.dart';

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

Map<String, dynamic> _receiptDetail() => <String, dynamic>{
  'id': 'receipt-collapse',
  'makerId': 'maker-1',
  'billNo': 'WR-2026-777',
  'billDate': '2026-09-11',
  'makerName': '仓管员',
  'createdAt': '2026-09-11T10:00:00+08:00',
  'supplierId': 'sup-1',
  'warehouseId': 'wh-1',
  'status': 0,
  'totalLocal': 120.0,
  'items': <Map<String, dynamic>>[
    for (var i = 0; i < 18; i++)
      <String, dynamic>{
        'id': 'ri-$i',
        'goodsId': 'g1',
        'colorId': 'c1',
        'unitId': 'u1',
        'qty': i + 1,
        'price': 5,
      },
  ],
};

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  double textScale = 1.0,
}) async {
  useUtenViewport(tester, size);
  final api = _api(
    (request) => request.path.contains('/subcontract/receipts/receipt-collapse')
        ? _receiptDetail()
        : <Object?>[],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        subcontractWriteAllDocumentScope(),
        currentPermissionsProvider.overrideWithValue(const <String>{
          Perm.subcontractReceiptView,
        }),
        subcontractRepositoryProvider(
          SubcontractDocType.receipt,
        ).overrideWithValue(
          SubcontractRepository(api, SubcontractDocType.receipt),
        ),
        mn.masterNameServiceProvider.overrideWithValue(
          mn.MasterNameService(api),
        ),
      ],
      child: MaterialApp(
        builder: utenTextScaleBuilder(textScale),
        home: const SubcontractDocDetailPage(
          docType: SubcontractDocType.receipt,
          id: 'receipt-collapse',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('委外进仓详情：上滚先收表头卡，明细表接着内滚', (tester) async {
    await _pump(tester, size: const Size(1280, 900));

    expect(find.byType(UtenCollapsingHeaderScrollView), findsOneWidget);
    expect(find.text('明细 (18)'), findsOneWidget);
    await expectUtenHeaderCollapses(
      tester,
      headerAnchor: find.text('单据号'),
      bodyAnchor: find.byType(MasterDataTableView<SubcontractDocItem>),
    );
    expect(find.text('明细 (18)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final viewport in utenCollapsingViewports) {
    testWidgets('委外进仓详情 ${viewport.label} · textScale 1.5 不溢出', (tester) async {
      await _pump(tester, size: viewport.size, textScale: 1.5);
      await expectUtenBodyReachable(
        tester,
        bodyAnchor: find.byType(MasterDataTableView<SubcontractDocItem>),
      );
    });
  }
}
