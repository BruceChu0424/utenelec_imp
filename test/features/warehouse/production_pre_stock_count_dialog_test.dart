import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/models/production_finished_inbound_task.dart';
import 'package:uten_imp/features/warehouse/widgets/production_pre_stock_count_dialog.dart';

void main() {
  const first = ProductionFinishedArrivalRegistrationItem(
    reportItemId: 'first',
    lineNo: 1,
    goodsId: 'goods',
    goodsCode: 'G001',
    goodsName: '同款自制件',
    reportedQty: 10,
    planNo: '计划一',
  );
  const second = ProductionFinishedArrivalRegistrationItem(
    reportItemId: 'second',
    lineNo: 2,
    goodsId: 'goods',
    goodsCode: 'G001',
    goodsName: '同款自制件',
    reportedQty: 20,
    planNo: '计划二',
  );

  testWidgets(
    'same product on two sources requires two physical counts at phone width',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Map<String, double>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showProductionPreStockCountDialog(context, [
                    first,
                    second,
                  ]);
                },
                child: const Text('核对'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('核对'));
      await tester.pumpAndSettle();
      final fields = tester.widgetList<TextField>(find.byType(TextField));
      expect(fields.every((field) => field.controller!.text.isEmpty), isTrue);
      await tester.enterText(
        find.byKey(const Key('production-prestock-count-first')),
        '10',
      );
      await tester.tap(
        find.byKey(const Key('production-prestock-count-confirm')),
      );
      await tester.pumpAndSettle();
      expect(result, isNull, reason: '同货品也必须分别确认两个来源');
      await tester.enterText(
        find.byKey(const Key('production-prestock-count-second')),
        '20',
      );
      await tester.tap(
        find.byKey(const Key('production-prestock-count-confirm')),
      );
      await tester.pumpAndSettle();
      expect(result, {'first': 10, 'second': 20});
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'historical missing count remains unknown, while confirmed count is read back',
    () {
      const json = <String, dynamic>{
        'reportItemId': 'first',
        'reportedQty': 10,
      };
      expect(
        ProductionFinishedArrivalRegistrationItem.fromJson(json).countedQty,
        isNull,
      );
      expect(
        ProductionFinishedArrivalRegistrationItem.fromJson({
          ...json,
          'countedQty': 10,
        }).countedQty,
        10,
      );
    },
  );
}
