import '../../../support/native_detail_reader_overrides.dart';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_detail_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test('detail parses personnel names without inventing historical UUIDs', () {
    final detail = SalesDocDetail.fromJson(const {
      'id': 'historical-sale',
      'legacyId': 42,
      'sellerName': '历史业务员(UT0191)',
      'senderName': '历史发货人(UT0192)',
    });
    expect(detail.legacyId, 42);
    expect(detail.sellerName, '历史业务员(UT0191)');
    expect(detail.senderName, '历史发货人(UT0192)');
    expect(detail.sellerId, isNull);
    expect(detail.senderId, isNull);
    expect(detail.makerId, isNull);
    expect(detail.approverId, isNull);
  });

  test(
    'old detail payload remains compatible when personnel names are absent',
    () {
      final detail = SalesDocDetail.fromJson(const {
        'id': 'old-payload',
        'sellerId': 'employee-seller',
        'senderId': 'employee-sender',
      });
      expect(detail.sellerId, 'employee-seller');
      expect(detail.senderId, 'employee-sender');
      expect(detail.sellerName, isNull);
      expect(detail.senderName, isNull);
    },
  );

  for (final type in [
    SalesDocType.order,
    SalesDocType.shipment,
    SalesDocType.otherShipment,
    SalesDocType.returnDoc,
  ]) {
    testWidgets('${type.name} shows historical names without employee access', (
      tester,
    ) async {
      final api = await _pumpDetail(tester, type, const {
        'legacyId': 42,
        'sellerName': '历史业务员(UT0191)',
        'senderName': '历史发货人(UT0192)',
      });
      expect(find.text('历史业务员(UT0191)'), findsOneWidget);
      if (type == SalesDocType.shipment || type == SalesDocType.otherShipment) {
        expect(find.text('历史发货人(UT0192)'), findsOneWidget);
      }
      expect(api.employeeReads, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('server names take precedence without redundant employee reads', (
    tester,
  ) async {
    final api = await _pumpDetail(tester, SalesDocType.shipment, const {
      'sellerId': 'employee-seller',
      'senderId': 'employee-sender',
      'sellerName': '服务端业务员',
      'senderName': '服务端发货人',
    });
    expect(find.text('服务端业务员'), findsOneWidget);
    expect(find.text('服务端发货人'), findsOneWidget);
    expect(api.employeeReads, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('old backend falls back to employee UUID names', (tester) async {
    final api = await _pumpDetail(tester, SalesDocType.shipment, const {
      'sellerId': 'employee-seller',
      'senderId': 'employee-sender',
      'sellerName': ' ',
    });
    expect(find.text('字典业务员'), findsOneWidget);
    expect(find.text('字典发货人'), findsOneWidget);
    expect(
      api.employeeReads,
      unorderedEquals(['employee-seller', 'employee-sender']),
    );
    expect(tester.takeException(), isNull);
  });
}

Future<_DetailApi> _pumpDetail(
  WidgetTester tester,
  SalesDocType type,
  Map<String, dynamic> personnel,
) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final detail = <String, dynamic>{
    'id': 'sales-personnel-fixture',
    'billNo': '历史销售单',
    'status': 1,
    'shipmentKind': 'LEGACY',
    'warehouseWorkStatus': 'LEGACY_PENDING',
    'items': <Map<String, dynamic>>[],
    ...personnel,
  };
  final api = _DetailApi(detail);
  final names = SalesMasterNameService(api);
  addTearDown(names.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeDetailReaderOverrides(),
        apiClientProvider.overrideWithValue(api),
        salesMasterNameServiceProvider.overrideWithValue(names),
        currentPermissionsProvider.overrideWithValue(const <String>{}),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        home: SalesDocDetailPage(docType: type, id: detail['id'] as String),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // Sender is intentionally part of the existing expandable header details.
  await tester.tap(find.byKey(const ValueKey('detail-summary-toggle')));
  await tester.pumpAndSettle();
  return api;
}

class _DetailApi extends ApiClient {
  _DetailApi(this.detail) : super(Dio());

  final Map<String, dynamic> detail;
  final List<String> employeeReads = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    const prefix = '/org/employees/';
    if (path.startsWith(prefix)) {
      final id = path.substring(prefix.length);
      employeeReads.add(id);
      return {
        'id': id,
        'fullName': id == 'employee-seller' ? '字典业务员' : '字典发货人',
      };
    }
    return detail;
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}
