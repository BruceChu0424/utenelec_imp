import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_detail_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  testWidgets('view permission loads an approved return as read-only quality', (
    tester,
  ) async {
    final api = _ReturnQualityApi(qualityRows: [_qualityRow()]);

    await _pumpReturnDetail(
      tester,
      api,
      permissions: const {Perm.salesReturnQualityView},
    );

    expect(
      find.byKey(const ValueKey('sales-return-quality-card')),
      findsOneWidget,
    );
    expect(find.text('待质检（PENDING）'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('quality-remaining-return-item-1')),
        matching: find.text('10'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('当前为只读'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('quality-action-GOOD_RELEASE-return-item-1')),
      findsNothing,
    );
    expect(api.qualityReads, 1);
  });

  testWidgets('correct and dispose permissions expose only their own actions', (
    tester,
  ) async {
    final api = _ReturnQualityApi(
      qualityRows: [
        _qualityRow(releasedBaseQty: 2, remainingBaseQty: 8, status: 'PARTIAL'),
      ],
    );

    await _pumpReturnDetail(
      tester,
      api,
      permissions: const {
        Perm.salesReturnQualityView,
        Perm.salesReturnQualityCorrect,
      },
    );

    expect(
      find.byKey(const ValueKey('quality-correct-GOOD_RELEASE-return-item-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('quality-action-GOOD_RELEASE-return-item-1')),
      findsNothing,
    );
  });
  testWidgets('missing quality view permission makes no quality API request', (
    tester,
  ) async {
    final api = _ReturnQualityApi(qualityRows: [_qualityRow()]);

    await _pumpReturnDetail(tester, api, permissions: const {});

    expect(
      find.byKey(const ValueKey('sales-return-quality-card')),
      findsNothing,
    );
    expect(api.qualityReads, 0);
    expect(find.text('红冲'), findsNothing);
    expect(find.textContaining('当前账号不能核验质检冻结台账'), findsOneWidget);
  });

  testWidgets('quality card remains usable on a small dark-mode screen', (
    tester,
  ) async {
    final api = _ReturnQualityApi(qualityRows: [_qualityRow()]);

    await _pumpReturnDetail(
      tester,
      api,
      permissions: const {Perm.salesReturnQualityView},
      size: const Size(375, 812),
      theme: ThemeData.dark(useMaterial3: true),
    );

    expect(
      find.byKey(const ValueKey('sales-return-quality-card')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'historical empty projection is explicit and has no fake action',
    (tester) async {
      final api = _ReturnQualityApi(qualityRows: const []);

      await _pumpReturnDetail(
        tester,
        api,
        permissions: const {
          Perm.salesReturnQualityView,
          Perm.salesReturnQualityDispose,
        },
      );

      expect(
        find.byKey(const ValueKey('sales-return-quality-history-empty')),
        findsOneWidget,
      );
      expect(find.textContaining('系统不会补造收货或质检事实'), findsOneWidget);
      expect(find.text('良品释放'), findsNothing);
      expect(find.text('报废'), findsNothing);
      expect(find.text('红冲'), findsNothing);
    },
  );

  testWidgets('handler must enter quantity and reason before disposition', (
    tester,
  ) async {
    final api = _ReturnQualityApi(
      qualityRows: [_qualityRow()],
      disposedRows: [
        _qualityRow(
          releasedBaseQty: 2.5,
          remainingBaseQty: 7.5,
          status: 'PARTIAL',
        ),
      ],
    );

    await _pumpReturnDetail(
      tester,
      api,
      permissions: const {
        Perm.salesReturnQualityView,
        Perm.salesReturnQualityDispose,
      },
    );

    expect(
      find.byKey(const ValueKey('quality-action-REWORK-return-item-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('quality-action-SCRAP-return-item-1')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('quality-action-GOOD_RELEASE-return-item-1')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('return-quality-submit')));
    await tester.pump();
    expect(find.text('请输入大于 0、最多 4 位小数的数量'), findsOneWidget);
    expect(find.text('请填写处置原因或检验依据'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('return-quality-qty')),
      '2.5',
    );
    await tester.enterText(
      find.byKey(const ValueKey('return-quality-reason')),
      'IQC-20260801 合格',
    );
    await tester.tap(find.byKey(const ValueKey('return-quality-submit')));
    await tester.pumpAndSettle();

    expect(api.disposeBody, containsPair('action', 'GOOD_RELEASE'));
    expect(api.disposeBody, containsPair('baseQty', 2.5));
    expect(api.disposeBody, containsPair('reason', 'IQC-20260801 合格'));
    expect(
      api.disposeBody?['idempotencyKey'],
      matches(
        RegExp(
          r'^sales-return-quality-dispose-[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('quality-remaining-return-item-1')),
        matching: find.text('7.5'),
      ),
      findsOneWidget,
    );
    expect(find.text('部分处置（PARTIAL）'), findsOneWidget);
    expect(find.text('红冲'), findsNothing);
    expect(find.textContaining('已发生质检处置'), findsOneWidget);
  });

  testWidgets('one dialog reuses its nonce after an ambiguous response', (
    tester,
  ) async {
    final api = _ReturnQualityApi(
      qualityRows: [_qualityRow()],
      disposeFailures: 1,
    );

    await _pumpReturnDetail(
      tester,
      api,
      permissions: const {
        Perm.salesReturnQualityView,
        Perm.salesReturnQualityDispose,
      },
    );

    await tester.tap(
      find.byKey(const ValueKey('quality-action-GOOD_RELEASE-return-item-1')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('return-quality-qty')),
      '1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('return-quality-reason')),
      'inspection-pass',
    );
    await tester.tap(find.byKey(const ValueKey('return-quality-submit')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('return-quality-submit-error')),
      findsOneWidget,
    );
    expect(api.disposeBodies, hasLength(1));
    final firstKey = api.disposeBodies.single['idempotencyKey'];

    await tester.enterText(
      find.byKey(const ValueKey('return-quality-qty')),
      '2',
    );
    await tester.enterText(
      find.byKey(const ValueKey('return-quality-reason')),
      'inspection-pass-updated',
    );
    await tester.tap(find.byKey(const ValueKey('return-quality-submit')));
    await tester.pumpAndSettle();

    expect(api.disposeBodies, hasLength(2));
    expect(api.disposeBodies.last['idempotencyKey'], firstKey);
    expect(api.disposeBodies.first['baseQty'], 1);
    expect(api.disposeBodies.last['baseQty'], 2);
  });

  testWidgets('separate dialogs receive distinct command nonces', (
    tester,
  ) async {
    final api = _ReturnQualityApi(qualityRows: [_qualityRow()]);

    await _pumpReturnDetail(
      tester,
      api,
      permissions: const {
        Perm.salesReturnQualityView,
        Perm.salesReturnQualityDispose,
      },
    );

    Future<void> submit(String reason) async {
      await tester.tap(
        find.byKey(const ValueKey('quality-action-SCRAP-return-item-1')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('return-quality-qty')),
        '1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('return-quality-reason')),
        reason,
      );
      await tester.tap(find.byKey(const ValueKey('return-quality-submit')));
      await tester.pumpAndSettle();
    }

    await submit('scrap-same-payload');
    await submit('scrap-same-payload');

    expect(api.disposeBodies, hasLength(2));
    expect(
      api.disposeBodies.first['idempotencyKey'],
      isNot(api.disposeBodies.last['idempotencyKey']),
    );
  });
}

Future<void> _pumpReturnDetail(
  WidgetTester tester,
  _ReturnQualityApi api, {
  required Set<String> permissions,
  Size size = const Size(1500, 1200),
  ThemeData? theme,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(api),
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        theme: theme,
        home: const SalesDocDetailPage(
          docType: SalesDocType.returnDoc,
          id: 'return-1',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _ReturnQualityApi extends ApiClient {
  _ReturnQualityApi({
    required this.qualityRows,
    List<Map<String, dynamic>>? disposedRows,
    int disposeFailures = 0,
  }) : disposedRows = disposedRows ?? qualityRows,
       remainingDisposeFailures = disposeFailures,
       super(Dio());

  final List<Map<String, dynamic>> qualityRows;
  final List<Map<String, dynamic>> disposedRows;
  int qualityReads = 0;
  int remainingDisposeFailures;
  final List<Map<String, dynamic>> disposeBodies = [];
  Map<String, dynamic>? disposeBody;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {
    'id': 'return-1',
    'billNo': 'XT-20260801-001',
    'status': 1,
    'writable': true,
    'warehouseId': 'warehouse-1',
    'items': [
      {
        'id': 'return-item-1',
        'goodsId': 'goods-1',
        'colorId': 'color-1',
        'unitId': 'unit-1',
        'qty': 10,
        'price': 1,
      },
    ],
  };

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/returns/return-1/quality') {
      qualityReads++;
      return qualityRows;
    }
    if (path == ApiEndpoints.warehousesDict) {
      return const [
        {'id': 'warehouse-1', 'name': '成品仓'},
      ];
    }
    if (path == ApiEndpoints.colorsDict) {
      return const [
        {'id': 'color-1', 'name': '本色'},
      ];
    }
    if (path == ApiEndpoints.unitsDict) {
      return const [
        {'id': 'unit-1', 'name': '件'},
      ];
    }
    if (path == ApiEndpoints.goodsLookup) {
      return const [
        {'id': 'goods-1', 'name': '测试成品'},
      ];
    }
    return const [];
  }

  @override
  Future<List<Map<String, dynamic>>> postList(
    String path, {
    Object? body,
  }) async {
    expect(path, '/sales/returns/return-1/quality/return-item-1/dispose');
    final requestBody = Map<String, dynamic>.from(body! as Map);
    disposeBody = requestBody;
    disposeBodies.add(requestBody);
    if (remainingDisposeFailures > 0) {
      remainingDisposeFailures--;
      throw NetworkTimeoutException();
    }
    return disposedRows;
  }
}

Map<String, dynamic> _qualityRow({
  double releasedBaseQty = 0,
  double remainingBaseQty = 10,
  String status = 'PENDING',
}) => {
  'id': 'quality-1',
  'returnId': 'return-1',
  'returnItemId': 'return-item-1',
  'warehouseId': 'warehouse-1',
  'goodsId': 'goods-1',
  'colorId': 'color-1',
  'unitId': 'unit-1',
  'unitRate': 1,
  'receivedBaseQty': 10,
  'releasedBaseQty': releasedBaseQty,
  'scrappedBaseQty': 0,
  'reworkBaseQty': 0,
  'remainingBaseQty': remainingBaseQty,
  'status': status,
  'receivedAt': '2026-08-01T10:00:00+08:00',
  'updatedAt': '2026-08-01T10:00:00+08:00',
};
