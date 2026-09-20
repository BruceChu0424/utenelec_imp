import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/production/models/production_material_return.dart';
import 'package:uten_imp/features/production/repositories/production_material_repository.dart';
import 'package:uten_imp/features/production/widgets/production_material_settlement_sheet.dart';

class _Repository extends ProductionMaterialRepository {
  _Repository() : super(ApiClient(Dio()));
  double consumed = 0, pending = 0;
  bool returnCreated = false, cancelled = false;
  bool directLot = false;
  bool loseSettlementResponse = false, loseReturnResponse = false;
  String? returnBlockedReason;
  final settlementKeys = <String>[];
  final returnKeys = <String>[];
  final settled = <String>{}, requested = <String>{};
  final settlementBodies = <Map<String, dynamic>>[];
  final returnBodies = <Map<String, dynamic>>[];
  String? sourceSegment;
  double get available => 10 - consumed - pending;

  @override
  Future<ProductionMaterialCapabilities> capabilities(
    String planId, {
    String? executionSegmentId,
  }) async => const ProductionMaterialCapabilities(
    canSettle: true,
    canRequestReturn: true,
  );

  @override
  Future<List<ProductionMaterialClearanceRow>> clearance(
    String planId, {
    String? executionSegmentId,
  }) async => [
    ProductionMaterialClearanceRow(
      planId: planId,
      demandId: 'demand',
      goodsId: 'goods',
      goodsName: '铝件',
      unitName: '件',
      executionSegmentId: 'task',
      requiredQty: 10,
      issuedQty: 10,
      returnedQty: 0,
      consumedQty: consumed,
      approvedLossQty: 0,
      legalWipQty: 0,
      maxReturnQty: available,
      unclearedQty: 10 - consumed,
      pendingReturnQty: pending,
      availableToSettleQty: available,
      canClose: false,
    ),
  ];

  @override
  Future<List<ProductionMaterialSettlementSource>> settlementSources(
    String planId, {
    String? executionSegmentId,
  }) async => [];

  @override
  Future<List<ProductionMaterialClearanceRow>> settle(
    String planId, {
    required String idempotencyKey,
    required List<ProductionMaterialSettlementLine> lines,
    String? reason,
    String? executionSegmentId,
  }) async {
    settlementKeys.add(idempotencyKey);
    settlementBodies.add({
      'lines': lines.map((line) => line.toJson()).toList(),
      'reason': reason,
      'executionSegmentId': executionSegmentId,
    });
    if (settled.add(idempotencyKey)) {
      consumed += lines.fold<double>(0, (sum, line) => sum + line.qtyBase);
    }
    if (loseSettlementResponse) {
      loseSettlementResponse = false;
      throw NetworkTimeoutException();
    }
    return clearance(planId, executionSegmentId: executionSegmentId);
  }

  @override
  Future<List<ProductionMaterialReturnSource>> returnSources(
    String planId, {
    String? executionSegmentId,
  }) async {
    sourceSegment = executionSegmentId;
    return [
      ProductionMaterialReturnSource.fromJson({
        'sourceType': directLot ? 'DIRECT_LOT' : 'ISSUE',
        'directTransferItemId': directLot ? 'direct-lot' : null,
        'issuePostingId': directLot ? null : 'issue',
        'demandId': 'demand',
        'drawId': directLot ? null : 'draw',
        'drawNo': 'LL001',
        'drawItemId': directLot ? null : 'draw-item',
        'sourceWarehouseId': 'leaf',
        'sourceWarehouseName': '五金分仓',
        'goodsId': 'goods',
        'goodsCode': 'WL001',
        'goodsName': '铝件',
        'colorId': 'silver',
        'colorName': '银色',
        'unitId': 'piece',
        'unitName': '件',
        'unitRate': 1,
        'issuedQty': 10,
        'unsettledQty': 10 - consumed,
        'pendingReturnQty': pending,
        'availableQty': returnBlockedReason == null ? available : 0,
        'returnBlockedReason': returnBlockedReason,
      }),
    ];
  }

  ProductionMaterialReturnDocument get document =>
      ProductionMaterialReturnDocument.fromJson({
        'documentId': 'return',
        'documentNo': 'TL001',
        'warehouseId': 'leaf',
        'warehouseName': '五金分仓',
        'status': cancelled ? 'CANCELLED' : 'PENDING',
        'lines': [
          {
            'itemId': 'return-item',
            'sourceType': 'ISSUE',
            'issuePostingId': 'issue',
            'demandId': 'demand',
            'drawItemId': 'draw-item',
            'goodsCode': 'WL001',
            'goodsName': '铝件',
            'colorName': '银色',
            'unitName': '件',
            'qty': 2,
            'baseQty': 2,
          },
        ],
      });

  @override
  Future<List<ProductionMaterialReturnDocument>> returnRequests(
    String planId, {
    String? executionSegmentId,
  }) async => returnCreated ? [document] : [];

  @override
  Future<List<ProductionMaterialReturnDocument>> requestReturn(
    String planId, {
    required String idempotencyKey,
    required List<Map<String, dynamic>> items,
    String? reason,
    String? executionSegmentId,
  }) async {
    returnKeys.add(idempotencyKey);
    returnBodies.add({
      'items': items,
      'reason': reason,
      'executionSegmentId': executionSegmentId,
    });
    if (requested.add(idempotencyKey)) {
      pending += items.fold<double>(
        0,
        (sum, item) => sum + (item['qty'] as num).toDouble(),
      );
      returnCreated = true;
    }
    if (loseReturnResponse) {
      loseReturnResponse = false;
      throw NetworkTimeoutException();
    }
    return [document];
  }

  @override
  Future<ProductionMaterialReturnDocument> cancelReturn(
    String planId,
    String documentId, {
    required String idempotencyKey,
    required String reason,
  }) async {
    pending = 0;
    cancelled = true;
    return document;
  }
}

Future<void> _open(
  WidgetTester tester,
  _Repository repository, {
  Size size = const Size(1300, 1050),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionMaterialRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => showProductionMaterialSettlementSheet(
                context,
                ref,
                planId: 'plan',
                executionSegmentId: 'task',
                canSettle: true,
                canReverse: false,
                canClose: false,
              ),
              child: const Text('打开用料'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开用料'));
  await tester.pumpAndSettle();
}

Future<void> _consume(WidgetTester tester, String qty) async {
  await tester.enterText(
    find.byKey(const ValueKey('material-consume-demand')),
    qty,
  );
  await tester.ensureVisible(find.text('提交用料登记'));
  await tester.tap(find.text('提交用料登记'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'unissued direct lot sends its exact source without inventing an issue or receiving warehouse',
    (tester) async {
      final repository = _Repository()..directLot = true;
      await _open(tester, repository);
      await tester.ensureVisible(find.text('余料退库'));
      await tester.tap(find.text('余料退库'));
      await tester.pumpAndSettle();
      expect(find.text('车间直送（未投用）'), findsOneWidget);
      expect(find.text('来源位置'), findsOneWidget);
      expect(find.text('退入仓库'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('material-return-qty-direct-direct-lot')),
        '2',
      );
      await tester.ensureVisible(
        find.byKey(const Key('material-return-submit')),
      );
      await tester.tap(find.byKey(const Key('material-return-submit')));
      await tester.pumpAndSettle();
      expect(repository.returnBodies.single['items'], [
        {'directTransferItemId': 'direct-lot', 'qty': 2.0},
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'pending direct return has nullable real destination and exact source lineage',
    () {
      final document = ProductionMaterialReturnDocument.fromJson({
        'documentId': 'return',
        'status': 'PENDING',
        'warehouseId': null,
        'sourceWarehouseId': 'technical',
        'sourceWarehouseName': '车间位置',
        'lines': [
          {
            'itemId': 'item',
            'demandId': 'demand',
            'sourceType': 'DIRECT_LOT',
            'directTransferItemId': 'lot',
            'issuePostingId': null,
            'drawItemId': null,
            'qty': 2,
            'baseQty': 2,
          },
        ],
      });
      expect(document.warehouseId, isNull);
      expect(document.warehouseName, '待仓库确认');
      expect(document.sourceWarehouseId, 'technical');
      expect(document.lines.single.issuePostingId, isNull);
      expect(document.lines.single.directTransferItemId, 'lot');
    },
  );

  testWidgets(
    'material carried into a later batch shows why it cannot be returned',
    (tester) async {
      const reason = '此物料已被后续生产批次承接，请先保留后续批次用料';
      final repository = _Repository()..returnBlockedReason = reason;
      await _open(tester, repository);
      await tester.ensureVisible(find.text('余料退库'));
      await tester.tap(find.text('余料退库'));
      await tester.pumpAndSettle();
      expect(find.byTooltip(reason), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('material-return-qty-issue')),
            )
            .enabled,
        isFalse,
      );
      expect(repository.returnKeys, isEmpty);
    },
  );

  for (final returning in [false, true]) {
    testWidgets(
      'compact ${returning ? 'return' : 'consumption'} uncertain response survives drag backdrop and system back',
      (tester) async {
        final repository = _Repository()
          ..loseSettlementResponse = !returning
          ..loseReturnResponse = returning;
        await _open(tester, repository, size: const Size(390, 844));
        if (returning) {
          await tester.ensureVisible(find.text('余料退库'));
          await tester.tap(find.text('余料退库'));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('material-return-qty-issue')),
            '2',
          );
          await tester.ensureVisible(
            find.byKey(const Key('material-return-submit')),
          );
          await tester.tap(find.byKey(const Key('material-return-submit')));
          await tester.pumpAndSettle();
        } else {
          await _consume(tester, '3');
        }
        final retry = returning ? '重试本次申请' : '重试本次登记';
        expect(find.text(retry), findsOneWidget);
        await tester.drag(
          find.text(returning ? '核对余料退仓' : '登记实际用料'),
          const Offset(0, 700),
        );
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text(retry), findsOneWidget);
        await tester.ensureVisible(find.text(retry));
        await tester.tap(find.text(retry));
        await tester.pumpAndSettle();
        final keys = returning
            ? repository.returnKeys
            : repository.settlementKeys;
        expect(keys, hasLength(2));
        expect(keys.first, keys.last);
        expect(
          returning ? repository.pending : repository.consumed,
          returning ? 2 : 3,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'identical quantities in successive production batches create distinct intentions',
    (tester) async {
      final repository = _Repository();
      await _open(tester, repository);
      expect(find.text('单位'), findsOneWidget);
      await _consume(tester, '3');
      expect(find.text('本次剩余物料'), findsOneWidget);
      expect(find.text('铝件：7 件'), findsOneWidget);
      await tester.tap(find.text('留待后续生产'));
      await tester.pumpAndSettle();
      expect(repository.returnKeys, isEmpty);
      expect(repository.consumed, 3);
      await _consume(tester, '3');
      expect(repository.settlementKeys, hasLength(2));
      expect(repository.settlementKeys[0], isNot(repository.settlementKeys[1]));
      expect(repository.consumed, 6);
      expect(find.text('铝件：4 件'), findsOneWidget);
      expect(
        repository.settlementBodies.every(
          (body) => body['executionSegmentId'] == 'task',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lost consumption receipt freezes inputs and retries the same payload without double consumption',
    (tester) async {
      final repository = _Repository()..loseSettlementResponse = true;
      await _open(tester, repository);
      await _consume(tester, '3');
      expect(find.text('重试本次登记'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('material-consume-demand')),
            )
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '刷新',
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('重试本次登记'));
      await tester.pumpAndSettle();
      expect(repository.settlementKeys, hasLength(2));
      expect(repository.settlementKeys[0], repository.settlementKeys[1]);
      expect(repository.settlementBodies[0], repository.settlementBodies[1]);
      expect(repository.consumed, 3);
      expect(find.text('铝件：7 件'), findsOneWidget);
    },
  );

  testWidgets(
    'partial return is explicit, pending receipt freezes balance, and cancellation restores it',
    (tester) async {
      final repository = _Repository();
      await _open(tester, repository);
      await _consume(tester, '3');
      await tester.tap(find.text('核对退仓'));
      await tester.pumpAndSettle();
      expect(repository.sourceSegment, 'task');
      expect(repository.returnKeys, isEmpty);
      expect(find.text('五金分仓'), findsOneWidget);
      final qty = find.byKey(const ValueKey('material-return-qty-issue'));
      expect(tester.widget<TextField>(qty).controller!.text, isEmpty);
      await tester.enterText(qty, '2');
      await tester.ensureVisible(
        find.byKey(const Key('material-return-submit')),
      );
      await tester.tap(find.byKey(const Key('material-return-submit')));
      await tester.pumpAndSettle();
      expect(repository.returnBodies.single['items'], [
        {'issuePostingId': 'issue', 'qty': 2.0},
      ]);
      expect(repository.pending, 2);
      expect(repository.available, 5);
      expect(find.textContaining('TL001 · 五金分仓 · 待仓库收料'), findsOneWidget);
      await tester.ensureVisible(find.text('撤回申请'));
      await tester.tap(find.text('撤回申请'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '撤回原因'), '留待下一批生产');
      await tester.tap(find.text('确认撤回'));
      await tester.pumpAndSettle();
      expect(repository.pending, 0);
      expect(repository.available, 7);
      expect(find.textContaining('TL001 · 五金分仓 · 已撤回'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown return response keeps the exact request and prevents quantity edits',
    (tester) async {
      final repository = _Repository()..loseReturnResponse = true;
      await _open(tester, repository);
      await tester.ensureVisible(find.text('余料退库'));
      await tester.tap(find.text('余料退库'));
      await tester.pumpAndSettle();
      final qty = find.byKey(const ValueKey('material-return-qty-issue'));
      await tester.enterText(qty, '2');
      await tester.ensureVisible(
        find.byKey(const Key('material-return-submit')),
      );
      await tester.tap(find.byKey(const Key('material-return-submit')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(qty).enabled, isFalse);
      await tester.tap(find.text('重试本次申请'));
      await tester.pumpAndSettle();
      expect(repository.returnKeys[0], repository.returnKeys[1]);
      expect(repository.returnBodies[0], repository.returnBodies[1]);
      expect(repository.pending, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
