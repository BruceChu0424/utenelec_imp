import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/repositories/production_material_repository.dart';
import 'package:uten_imp/features/production/widgets/production_material_settlement_sheet.dart';

void main() {
  testWidgets(
    'mixed units stay per demand and settled rows leave the primary input grid',
    (tester) async {
      final fixture = _Fixture(mixedUnits: true);
      await _open(tester, fixture, width: 900);
      expect(find.text('待登记材料（2 项）'), findsOneWidget);
      expect(find.text('3 项'), findsOneWidget);
      expect(find.text('单位：件'), findsOneWidget);
      expect(find.text('单位：千克'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('material-consume-cleared')),
        findsNothing,
      );
      expect(find.text('已结清原料'), findsNothing);
      expect(find.text('每项：已领 = 实耗 + 已退 + 损耗 + 在制 + 待登记'), findsOneWidget);
      await tester.ensureVisible(find.text('材料数量台账'));
      await tester.tap(find.text('材料数量台账'));
      await tester.pumpAndSettle();
      expect(find.text('已结清原料'), findsOneWidget);
      expect(find.text('实耗 7 件'), findsOneWidget);
      expect(find.text('待登记 0.25 千克'), findsOneWidget);
      expect(fixture.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'usage cap and mandatory loss reason remain before one typed scoped submission',
    (tester) async {
      final fixture = _Fixture();
      await _open(tester, fixture);
      expect(
        find.byKey(const ValueKey('material-loss-material')),
        findsNothing,
      );
      await tester.tap(find.text('填写损耗 / 在制'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('material-consume-material')),
        '8',
      );
      await tester.enterText(
        find.byKey(const ValueKey('material-loss-material')),
        '3',
      );
      await tester.ensureVisible(find.text('提交用料登记'));
      await tester.tap(find.text('提交用料登记'));
      await tester.pumpAndSettle();
      expect(
        fixture.writes,
        isEmpty,
        reason: '11 exceeds the actual outstanding 10',
      );
      await tester.enterText(
        find.byKey(const ValueKey('material-consume-material')),
        '6',
      );
      await tester.enterText(
        find.byKey(const ValueKey('material-loss-material')),
        '2',
      );
      await tester.enterText(
        find.byKey(const ValueKey('material-wip-material')),
        '2',
      );
      await tester.ensureVisible(find.text('提交用料登记'));
      await tester.tap(find.text('提交用料登记'));
      await tester.pumpAndSettle();
      expect(
        fixture.writes,
        isEmpty,
        reason: 'loss and WIP require the actor reason',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '本次说明'),
        '切边损耗及留在本工单的在制材料',
      );
      await tester.tap(find.text('提交用料登记'));
      await tester.pumpAndSettle();
      expect(fixture.writes, hasLength(1));
      final payload = fixture.writes.single.data as Map<String, dynamic>;
      expect(payload['executionSegmentId'], 'task');
      expect(payload['reason'], '切边损耗及留在本工单的在制材料');
      expect(payload['lines'], [
        {'demandId': 'material', 'settlementType': 'CONSUMED', 'qtyBase': 6.0},
        {
          'demandId': 'material',
          'settlementType': 'APPROVED_LOSS',
          'qtyBase': 2.0,
        },
        {'demandId': 'material', 'settlementType': 'LEGAL_WIP', 'qtyBase': 2.0},
      ]);
      expect(
        find.text('提交用料登记'),
        findsNothing,
        reason: 'fresh zero balance only exposes records',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'collapsed history still reverses the exact original posting with reason and cap',
    (tester) async {
      final fixture = _Fixture(historyOnly: true);
      await _open(tester, fixture);
      expect(find.text('提交用料登记'), findsNothing);
      expect(find.text('冲销'), findsNothing);
      await tester.ensureVisible(find.text('有效登记与冲销（1 条）'));
      await tester.tap(find.text('有效登记与冲销（1 条）'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('冲销'));
      await tester.tap(find.text('冲销'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认冲销'));
      await tester.pumpAndSettle();
      expect(fixture.writes, isEmpty);
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.first, '11');
      await tester.enterText(fields.last, '原记录数量录入错误');
      await tester.tap(find.text('确认冲销'));
      await tester.pumpAndSettle();
      expect(fixture.writes, isEmpty);
      await tester.enterText(fields.first, '3');
      await tester.tap(find.text('确认冲销'));
      await tester.pumpAndSettle();
      expect(fixture.writes, hasLength(1));
      final request = fixture.writes.single;
      expect(request.path, endsWith('/settlements/reverse'));
      final payload = request.data as Map<String, dynamic>;
      expect(payload['executionSegmentId'], 'task');
      expect(payload['reason'], '原记录数量录入错误');
      expect(payload['lines'], [
        {
          'demandId': 'material',
          'settlementType': 'CONSUMED',
          'qtyBase': 3.0,
          'sourcePostingId': 'original-posting',
        },
      ]);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _open(
  WidgetTester tester,
  _Fixture fixture, {
  double width = 1100,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionMaterialRepositoryProvider.overrideWithValue(
          fixture.repository,
        ),
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
                canReverse: true,
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

class _Fixture {
  _Fixture({this.mixedUnits = false, this.historyOnly = false}) {
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          Object data;
          if (request.method == 'POST') {
            writes.add(request);
            data = <Object>[];
          } else if (request.path.endsWith('/capabilities')) {
            data = {'canSettle': true, 'canReverse': true, 'canClose': false};
          } else if (request.path.endsWith('/clearance')) {
            data = [
              _row(
                'material',
                '本工单原料',
                '件',
                historyOnly || writes.isNotEmpty ? 0 : 10,
                10,
              ),
              if (mixedUnits) _row('weight', '称重原料', '千克', 0.25, 0.25),
              if (mixedUnits) _row('cleared', '已结清原料', '件', 0, 7),
            ];
          } else {
            data = historyOnly
                ? [
                    {
                      'postingId': 'original-posting',
                      'eventId': 'original-event',
                      'demandId': 'material',
                      'goodsId': 'goods-material',
                      'goodsName': '本工单原料',
                      'settlementType': 'CONSUMED',
                      'postedQtyBase': 10,
                      'reversibleQtyBase': 10,
                      'reversedQtyBase': 0,
                      'createdAt': '2026-09-08T10:00:00Z',
                    },
                  ]
                : <Object>[];
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: data,
            ),
          );
        },
      ),
    );
    repository = ProductionMaterialRepository(ApiClient(dio));
  }
  final bool mixedUnits;
  final bool historyOnly;
  final writes = <RequestOptions>[];
  late final ProductionMaterialRepository repository;
  Map<String, dynamic> _row(
    String id,
    String name,
    String unit,
    num pending,
    num issued,
  ) => {
    'planId': 'plan',
    'demandId': id,
    'executionSegmentId': 'task',
    'goodsId': 'goods-$id',
    'goodsName': name,
    'unitName': unit,
    'requiredQty': issued,
    'issuedQty': issued,
    'unclearedQty': pending,
    'consumedQty': issued - pending,
    'maxReturnQty': pending,
    'canClose': pending == 0,
  };
}
