// 新建采购订货单「勾选口径」测试（2026-09-17 用户口径）：
//   1. 任务中心带单进入 → 明细行默认全选（保存只认勾选行，默认全选=旧行为不变）；
//   2. 全部取消勾选 → 右下「保存」置灰，灰态点击说明原因（没选不给点）；
//   3. 只勾一部分保存 → 先弹「有 N 行未勾选」确认，确认后行级校验只针对
//      勾选行（未勾选行不进本次提交集，不参与校验也不生成订货）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/purchase/pages/purchase_order_edit_page.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets(
    'frozen alternate source rate stays exact in the real save command and distinct merge keys',
    (tester) async {
      final source1 = _preview('source-1', '0.0001', '0', '0.0001')
        ..['unitId'] = 'alternate-unit'
        ..['unitRate'] = 1000000000000
        ..['unitRateExact'] = '999999999999.999999';
      final source2 = _preview('source-2', '0.0001', '0', '0.0001')
        ..['unitId'] = 'alternate-unit'
        ..['unitRate'] = 1000000000000
        ..['unitRateExact'] = '999999999999.999998';
      final api = _RateSourceApi([source1, source2]);
      await tester.binding.setSurfaceSize(const Size(1600, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final router = GoRouter(
        initialLocation: '/edit',
        routes: [
          GoRoute(
            path: '/edit',
            builder: (_, _) => const PurchaseOrderEditPage(
              sourceRequestItemIds: ['source-1', 'source-2'],
            ),
          ),
          GoRoute(
            path: '/purchase/orders/:id',
            builder: (_, _) => const Scaffold(body: Text('已保存来源订单')),
          ),
          GoRoute(
            path: RouteName.operationsPurchaseWorkbench,
            builder: (_, _) => const Scaffold(body: Text('采购任务中心')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
            apiClientProvider.overrideWithValue(api),
            sessionProvider.overrideWith(_EmptySessionNotifier.new),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      final grid = tester.widget<UtenEditableGrid<PurchaseGridRow>>(
        find.byType(UtenEditableGrid<PurchaseGridRow>),
      );
      expect(grid.controller.rows, hasLength(2));
      expect(grid.controller.rows.map((r) => r.recordedUnitRateText), [
        '999999999999.999999',
        '999999999999.999998',
      ]);
      for (final row in grid.controller.rows) {
        expect(row.supplierId, 's1');
        expect(row.settlementMethodId, 'settle-1');
        expect(row.currencyId, 'cny');
        expect(row.unitRateInputValid, isTrue);
        await tester.enterText(
          find.byWidgetPredicate(
            (w) => w is TextField && identical(w.controller, row.price),
          ),
          '1',
        );
      }
      final save = find.byKey(const ValueKey('uten-edit-save'));
      expect(grid.controller.selectedRows, hasLength(2));
      expect(tester.widget<UtenButton>(save).onPressed, isNotNull);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(api.savedBodies, hasLength(1));
      final lines = (api.savedBodies.single['items'] as List)
          .cast<Map<String, dynamic>>();
      expect(lines.map((line) => line['unitRate']), [
        '999999999999.999999',
        '999999999999.999998',
      ]);
      expect(lines.every((line) => line['unitRate'] is String), isTrue);
      expect(lines.map((line) => line['requestItemId']), [
        'source-1',
        'source-2',
      ]);
      expect(lines.map((line) => line['unitId']), [
        'alternate-unit',
        'alternate-unit',
      ]);
      expect(lines.map((line) => line['qty']), ['0.0001', '0.0001']);
      expect(
        router.routeInformationProvider.value.uri.path,
        RouteName.operationsPurchaseWorkbench,
      );
      expect(find.text('采购任务中心'), findsOneWidget);
      expect(find.text('已保存来源订单'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'FIFO preview merges exact paid quantities and keeps every source identity',
    (tester) async {
      final api = _SelectionApi(
        previewRows: [
          _preview(
            'source-1',
            '99999999999999.1234',
            '0',
            '99999999999999.1234',
          ),
          _preview('source-2', '0.0001', '0', '0.0001'),
        ],
      );
      await _openSourcePreview(tester, api);
      final grid = tester.widget<UtenEditableGrid<PurchaseGridRow>>(
        find.byType(UtenEditableGrid<PurchaseGridRow>),
      );
      final row = grid.controller.rows.single;
      expect(row.qty.text, '99999999999999.1235');
      expect(row.giftQty.text, '0');
      expect(row.physicalQtyText, '99999999999999.1235');
      expect(row.upstreamItemIds, ['source-1', 'source-2']);
      expect(row.sourceDocs.map((s) => s.requestItemId), [
        'source-1',
        'source-2',
      ]);
      expect(tester.takeException(), isNull);
    },
  );
  for (final (paid, gift, physical) in [
    ('0', '1', '1'),
    ('1', '0', '1'),
    ('0.0001', '0', '0.0001'),
  ]) {
    testWidgets(
      'FIFO default preserves charged $paid gift $gift physical $physical',
      (tester) async {
        await _openSourcePreview(
          tester,
          _SelectionApi(
            previewRows: [_preview('source-1', paid, gift, physical)],
          ),
        );
        final grid = tester.widget<UtenEditableGrid<PurchaseGridRow>>(
          find.byType(UtenEditableGrid<PurchaseGridRow>),
        );
        final row = grid.controller.rows.single;
        expect(row.qty.text, paid);
        expect(row.giftQty.text, gift);
        expect(row.physicalQtyText, physical);
        expect(row.upstreamItemIds, ['source-1']);
        expect(
          row.maxGiftQtyText,
          isNull,
          reason:
              'New orders permit extra gifts; declared gift remainder is a default, not a hard quota',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'legacy request gift annotation is not prefilled as extra physical supply',
    (tester) async {
      final line = _preview('source-1', '10', '0', '10')
        ..['quantitySemantics'] = 'LEGACY_RECORDED'
        ..['giftQtyExact'] = '1';
      await _openSourcePreview(tester, _SelectionApi(previewRows: [line]));
      final grid = tester.widget<UtenEditableGrid<PurchaseGridRow>>(
        find.byType(UtenEditableGrid<PurchaseGridRow>),
      );
      expect(grid.controller.rows.single.qty.text, '10');
      expect(grid.controller.rows.single.giftQty.text, '0');
      expect(grid.controller.rows.single.physicalQtyText, '10');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('带单进入默认全选；取消全部勾选后保存置灰并说明原因；部分勾选只校验勾选行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
          apiClientProvider.overrideWithValue(_SelectionApi()),
          sessionProvider.overrideWith(_EmptySessionNotifier.new),
        ],
        child: const MaterialApp(
          home: Column(
            children: [
              AppNotificationHost(),
              Expanded(
                child: PurchaseOrderEditPage(
                  sourceRequestItemIds: ['it-1', 'it-2'],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 预填两行（两个货品）默认全选：两行复选框 + 表头全选框（树序：行框在前）。
    final checkboxes = find.byType(Checkbox);
    expect(checkboxes, findsNWidgets(3));
    expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isTrue);
    expect(tester.widget<Checkbox>(checkboxes.at(1)).value, isTrue);
    expect(tester.widget<Checkbox>(checkboxes.at(2)).value, isTrue);

    // 带单新建行的「编号」「颜色」独立列必须显示（2026-09-26 回归锁：引入行
    // 构造 GoodsOption 曾不带 code，编号列恒空；颜色按申请明细 colorId 查字典）。
    expect(find.text('V60000g-1'), findsOneWidget);
    expect(find.text('V60000g-2'), findsOneWidget);
    expect(find.text('白色'), findsOneWidget);
    expect(find.text('香槟金'), findsOneWidget);

    // 有勾选行 → 保存可点。
    final save = find.byKey(const ValueKey('uten-edit-save'));
    UtenButton saveButton() => tester.widget<UtenButton>(save);
    expect(saveButton().onPressed, isNotNull);

    // 两行全部取消勾选 → 保存置灰；灰态点击给出原因。
    await tester.tap(checkboxes.at(0));
    await tester.pump();
    await tester.tap(checkboxes.at(1));
    await tester.pump();
    expect(saveButton().onPressed, isNull);
    await tester.tap(save);
    await tester.pump();
    expect(find.textContaining('请先在明细表勾选要生成订货的行'), findsOneWidget);

    // 只勾第一行保存：有货品却未勾选的行先经确认，确认后校验只报勾选行。
    await tester.tap(checkboxes.at(0));
    await tester.pump();
    expect(saveButton().onPressed, isNotNull);
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('有 1 行明细未勾选'), findsOneWidget);
    await tester.tap(find.text('只提交勾选行'));
    await tester.pumpAndSettle();
    // 勾选行缺供应商/结账方式/币种 → 校验报「第 1 行」；未勾选的第二行不出现。
    expect(find.textContaining('第 1 行'), findsWidgets);
    expect(find.textContaining('第 2 行'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _RateSourceApi extends _SelectionApi {
  _RateSourceApi(List<Map<String, dynamic>> sources)
    : super(previewRows: sources);
  final savedBodies = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('last-terms')) {
      return {
        'same-goods': {
          'supplierId': 's1',
          'settlementMethodId': 'settle-1',
          'currencyId': 'cny',
          'taxRate': 0,
        },
      };
    }
    return super.get(path, query: query);
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.settlementMethods) {
      return [
        {
          'id': 'settle-1',
          'code': 'MONTHLY',
          'name': '月结',
          'legacyNameConfirmed': true,
        },
      ];
    }
    if (path.contains('currencies')) {
      return [
        {
          'id': 'cny',
          'code': 'CNY',
          'name': '人民币',
          'baseCurrency': true,
          'exchangeRate': 1,
        },
      ];
    }
    return super.getList(path, query: query);
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/batch')) {
      savedBodies.add(Map<String, dynamic>.from(body! as Map));
      return {
        'items': [
          {
            'id': 'saved',
            'billNo': 'CG-SAVED',
            'status': 0,
            'items': <Object>[],
          },
        ],
      };
    }
    if (path.startsWith('/task-claims/')) {
      final segments = path.split('/');
      return {
        'claimId': 'f0e13094-c8c9-4e67-a50a-7c6b58e09b49',
        'targetType': segments[2],
        'targetKey': segments[3],
        'claimedBy': 'fixture-employee',
        'claimedByName': '来源下单人',
        'claimedByMe': true,
        'claimedAt': DateTime.now().toUtc().toIso8601String(),
        'leaseUntil': '2099-10-12T00:00:00Z',
      };
    }
    return {};
  }
}

class _EmptySessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _SelectionApi extends ApiClient {
  _SelectionApi({this.previewRows}) : super(Dio());
  final List<Map<String, dynamic>>? previewRows;

  @override
  Future<List<Map<String, dynamic>>> postList(
    String path, {
    Object? body,
  }) async {
    if (path.contains('decomposition-preview')) {
      if (previewRows != null) return previewRows!;
      return const [
        {
          'sourceDocumentId': 'req-1',
          'sourceDocumentNo': 'CG-SQ-20260917-001',
          'sourceItemId': 'it-1',
          'goodsId': 'g-1',
          'requestedQty': 10,
          'orderedQty': 0,
          'pendingQty': 0,
          'remainingQty': 10,
          'colorId': 'c-1',
          'unitId': 'u-1',
          'needDate': '2026-09-20',
        },
        {
          'sourceDocumentId': 'req-1',
          'sourceDocumentNo': 'CG-SQ-20260917-001',
          'sourceItemId': 'it-2',
          'goodsId': 'g-2',
          'requestedQty': 5,
          'orderedQty': 0,
          'pendingQty': 0,
          'remainingQty': 5,
          'colorId': 'c-2',
          'unitId': 'u-1',
          'needDate': '2026-09-20',
        },
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('last-terms')) return const {};
    if (path.contains('/master/suppliers')) {
      return const {
        'items': <Map<String, dynamic>>[],
        'page': 1,
        'size': 20,
        'total': 0,
        'totalPages': 0,
      };
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
    if (path.contains('/master/suppliers/dict')) {
      return const [
        {'id': 's1', 'code': 'GY001', 'name': '洪武五金', 'status': '使用'},
      ];
    }
    if (path == ApiEndpoints.goodsLookup) {
      // 带单新建行的名称+编号都来自 lookup 字典（goodsOptionOf）。
      final ids = (query!['ids'] as String).split(',');
      return [
        for (final id in ids) {'id': id, 'name': '货品$id', 'code': 'V60000$id'},
      ];
    }
    if (path == ApiEndpoints.colorsDict) {
      return const [
        {'id': 'c-1', 'name': '白色'},
        {'id': 'c-2', 'name': '香槟金'},
      ];
    }
    return const [];
  }
}

Map<String, dynamic> _preview(
  String id,
  String paid,
  String gift,
  String physical,
) {
  final partlyFulfilled =
      paid == '0' && gift == '1' || paid == '1' && gift == '0';
  final requested = partlyFulfilled ? '10' : paid;
  final ordered = partlyFulfilled ? (paid == '0' ? '10' : '9') : '0';
  final giftOrdered = partlyFulfilled && paid == '1' ? '1' : '0';
  return {
    'sourceDocumentId': 'req-1',
    'sourceDocumentNo': 'CS-EXACT',
    'sourceItemId': id,
    'goodsId': 'same-goods',
    'unitId': 'u-1',
    'unitRate': 1,
    'requestedQty': double.parse(requested),
    'requestedQtyExact': requested,
    'orderedQty': double.parse(ordered),
    'orderedQtyExact': ordered,
    'pendingQty': 0,
    'pendingQtyExact': '0',
    'remainingQty': double.parse(paid),
    'remainingQtyExact': paid,
    'quantitySemantics': 'CHARGED_PLUS_GIFT_V1',
    'giftQtyExact': partlyFulfilled ? '1' : '0',
    'giftOrderedQtyExact': giftOrdered,
    'pendingGiftQtyExact': '0',
    'remainingGiftQtyExact': gift,
    'physicalQtyExact': partlyFulfilled ? '11' : paid,
    'physicalOrderedQtyExact': partlyFulfilled ? '10' : '0',
    'physicalPendingQtyExact': '0',
    'physicalRemainingQtyExact': physical,
  };
}

Future<void> _openSourcePreview(WidgetTester tester, _SelectionApi api) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
        apiClientProvider.overrideWithValue(api),
        sessionProvider.overrideWith(_EmptySessionNotifier.new),
      ],
      child: const MaterialApp(
        home: Column(
          children: [
            AppNotificationHost(),
            Expanded(
              child: PurchaseOrderEditPage(
                sourceRequestItemIds: ['source-1', 'source-2'],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byType(UtenEditableGrid<PurchaseGridRow>), findsOneWidget);
}
