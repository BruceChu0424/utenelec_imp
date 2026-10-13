import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/purchase/pages/purchase_order_edit_page.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/formatters/exact_decimal.dart';

Map<String, dynamic> preview(
  String id,
  String paid,
  String gift,
  String physical, {
  String goods = 'g',
  String semantics = 'CHARGED_PLUS_GIFT_V1',
}) => {
  'sourceDocumentId': 'request-$id',
  'sourceDocumentNo': 'CS-$id',
  'sourceItemId': id,
  'goodsId': goods,
  'unitId': 'unit',
  'unitRateExact': '1.000000',
  'quantitySemantics': semantics,
  'requestedQty': double.parse(paid),
  'requestedQtyExact': paid,
  'giftQtyExact': gift,
  'orderedQty': 0,
  'pendingQty': 0,
  'remainingQty': double.parse(paid),
  'remainingQtyExact': paid,
  'remainingGiftQtyExact': gift,
  'physicalRemainingQtyExact': physical,
};

Future<_PreviewApi> _pumpPreview(
  WidgetTester tester,
  List<Map<String, dynamic>> rows,
) async {
  await tester.binding.setSurfaceSize(const Size(1800, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = _PreviewApi(rows);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => PurchaseOrderEditPage(
          sourceRequestItemIds: rows
              .map((row) => row['sourceItemId'] as String)
              .toList(),
        ),
      ),
      GoRoute(
        path: '/purchase/orders/:id',
        builder: (_, _) => const SizedBox(),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
        apiClientProvider.overrideWithValue(api),
        sessionProvider.overrideWith(_Session.new),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        builder: (_, child) => Column(
          children: [
            const AppNotificationHost(),
            Expanded(child: child!),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

UtenEditableGrid<PurchaseGridRow> grid(WidgetTester tester) =>
    tester.widget<UtenEditableGrid<PurchaseGridRow>>(
      find.byType(UtenEditableGrid<PurchaseGridRow>),
    );

Future<void> save(WidgetTester tester) async {
  for (final row in grid(tester).controller.rows) {
    row.price.text = '0';
  }
  await tester.pumpAndSettle();
  final button = find.byKey(const ValueKey('uten-edit-save'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('legacy numeric source rate keeps its numeric payload fallback', (
    tester,
  ) async {
    final source = preview('old-rate', '100', '0', '100')
      ..remove('unitRateExact')
      ..['unitRate'] = 2.5;
    final api = await _pumpPreview(tester, [source]);
    final row = grid(tester).controller.rows.single;
    expect(row.unitRateText, isNull);
    expect(row.unitRate, 2.5);
    await save(tester);
    final saved = (api.saved!['items'] as List).single as Map;
    expect(saved['unitRate'], 2.5);
    expect(saved['unitRate'], isA<num>());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'legal 18,6 source rate reaches payload without losing the 0.0001 base quantum',
    (tester) async {
      const exact = '999999999999.000001';
      final source = preview('rate', '100', '0', '100')
        ..['unitRateExact'] = exact;
      final api = await _pumpPreview(tester, [source]);
      final row = grid(tester).controller.rows.single;
      expect(row.unitRateText, exact);
      await save(tester);
      final saved = (api.saved!['items'] as List).single as Map;
      expect(saved['unitRate'], exact);
      expect(
        financeExactDecimalFromUnits(
          financeExactProductUnits(
            saved['qty'] as String,
            saved['unitRate'] as String,
          )!,
        ),
        '99999999999900.0001',
      );
      expect(saved['requestItemId'], 'rate');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fully gift-covered need is omitted even if rounded legacy remaining says one',
    (tester) async {
      final covered = preview('covered', '0', '0', '0')
        ..['requestedQty'] = 10
        ..['requestedQtyExact'] = '10'
        ..['orderedQty'] = 9
        ..['orderedQtyExact'] = '9'
        ..['giftOrderedQtyExact'] = '1'
        ..['remainingQty'] = 1;
      await _pumpPreview(tester, [
        covered,
        preview('open', '2', '0', '2', goods: 'other'),
      ]);
      final rows = grid(tester).controller.rows;
      expect(rows, hasLength(1));
      expect(rows.single.goods!.id, 'other');
      expect(rows.single.qty.text, '2');
      expect(rows.single.giftQty.text, '0');
      expect(rows.single.upstreamItemIds, ['open']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('gift-only remainder saves zero paid and exact gift quantity', (
    tester,
  ) async {
    final api = await _pumpPreview(tester, [
      preview('free', '0', '0.0001', '0.0001'),
    ]);
    final row = grid(tester).controller.rows.single;
    expect(row.qty.text, '0');
    expect(row.giftQty.text, '0.0001');
    await save(tester);
    final saved = (api.saved!['items'] as List).single as Map;
    expect(saved['qty'], '0');
    expect(saved['giftQty'], '0.0001');
    expect(saved['requestItemId'], 'free');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'merged charged and gift remainders preserve every decimal and source',
    (tester) async {
      final api = await _pumpPreview(tester, [
        preview(
          'first',
          '12345678901234.0001',
          '0.0003',
          '12345678901234.0004',
        ),
        preview('second', '0.0002', '0.0004', '0.0006'),
      ]);
      final row = grid(tester).controller.rows.single;
      expect(row.qty.text, '12345678901234.0003');
      expect(row.giftQty.text, '0.0007');
      expect(row.upstreamItemIds, ['first', 'second']);
      expect(row.sourceDocs.map((ref) => ref.requestItemId), [
        'first',
        'second',
      ]);
      await save(tester);
      final saved = (api.saved!['items'] as List).single as Map;
      expect(saved['qty'], '12345678901234.0003');
      expect(saved['giftQty'], '0.0007');
      expect(saved['requestItemIds'], ['first', 'second']);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _PreviewApi extends ApiClient {
  _PreviewApi(this.rows) : super(Dio());
  final List<Map<String, dynamic>> rows;
  Map<String, dynamic>? saved;
  @override
  Future<List<Map<String, dynamic>>> postList(
    String path, {
    Object? body,
  }) async => path.contains('decomposition-preview') ? rows : [];
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/orders/batch')) {
      saved = Map<String, dynamic>.from(body as Map);
      return {'items': <Map<String, dynamic>>[]};
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/last-terms')) {
      return {
        for (final row in rows)
          row['goodsId'] as String: {
            'supplierId': 'supplier',
            'settlementMethodId': 'settlement',
            'currencyId': 'currency',
            'exchangeRate': 1,
            'taxRate': 0,
          },
      };
    }
    return {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 20,
      'total': 0,
      'totalPages': 0,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.goodsLookup) {
      return [
        for (final id in (query!['ids'] as String).split(','))
          {'id': id, 'name': 'Goods $id', 'code': id},
      ];
    }
    if (path == ApiEndpoints.suppliersDict) {
      return [
        {'id': 'supplier', 'name': 'Supplier', 'status': '使用'},
      ];
    }
    if (path == ApiEndpoints.currenciesDict) {
      return [
        {'id': 'currency', 'name': 'Currency'},
      ];
    }
    if (path == ApiEndpoints.settlementMethods) {
      return [
        {'id': 'settlement', 'name': 'Settlement', 'status': '使用'},
      ];
    }
    return [];
  }
}
