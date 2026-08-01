import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_edit_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets('new order defaults to customer-confirm shipment policy', (
    tester,
  ) async {
    await _pumpEditor(tester, type: SalesDocType.order);

    expect(
      find.byKey(const ValueKey('sales-order-shipment-policy')),
      findsOneWidget,
    );
    expect(find.text('客户确认后分批'), findsOneWidget);
    expect(find.textContaining('需要先在订单详情登记客户同意'), findsOneWidget);
  });

  testWidgets('legacy order keeps shipment policy read-only', (tester) async {
    await _pumpEditor(
      tester,
      type: SalesDocType.order,
      id: 'legacy-order',
      detail: const {
        'id': 'legacy-order',
        'status': 0,
        'writable': true,
        'shipmentPolicy': 'LEGACY_UNSPECIFIED',
        'items': <Map<String, dynamic>>[],
      },
    );

    expect(
      find.byKey(const ValueKey('sales-order-shipment-policy-readonly')),
      findsOneWidget,
    );
    expect(find.text('历史订单（未指定）'), findsOneWidget);
    expect(find.textContaining('编辑其它字段时系统会保留'), findsOneWidget);
  });

  testWidgets('new sales shipment explains mandatory order linkage', (
    tester,
  ) async {
    await _pumpEditor(tester, type: SalesDocType.shipment);

    expect(
      find.byKey(const ValueKey('sales-shipment-order-link-guidance')),
      findsOneWidget,
    );
    expect(find.textContaining('销售出货必须从订货单引入'), findsOneWidget);
  });
}

Future<void> _pumpEditor(
  WidgetTester tester, {
  required SalesDocType type,
  String? id,
  Map<String, dynamic>? detail,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final api = _EditorApi(detail);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(api),
        ),
        sessionProvider.overrideWith(_TestSessionNotifier.new),
      ],
      child: MaterialApp(
        home: SalesDocEditPage(docType: type, id: id),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _EditorApi extends ApiClient {
  _EditorApi(this.detail) : super(Dio());

  final Map<String, dynamic>? detail;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (detail != null && path.endsWith('/${detail!['id']}')) {
      return detail!;
    }
    return const {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 1,
      'total': 0,
      'totalPages': 0,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    return const [];
  }
}
