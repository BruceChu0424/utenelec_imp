import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/widgets/metric_filter_cards.dart';

void main() {
  for (final width in [360.0, 800.0, 1280.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('metrics fit width $width at text scale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 1600),
                  textScaler: TextScaler.linear(scale),
                ),
                child: SingleChildScrollView(
                  child: MetricFilterCards(items: _items(onTap: () => taps++)),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final cards = find.byType(InkWell);
        final rectangles = [
          for (var i = 0; i < 5; i++) tester.getRect(cards.at(i)),
        ];
        for (final rectangle in rectangles) {
          expect(rectangle.height, closeTo(rectangles.first.height, 0.001));
          expect(rectangle.left, greaterThanOrEqualTo(0));
          expect(rectangle.right, lessThanOrEqualTo(width));
          for (final peer in rectangles.where(
            (peer) => peer.top == rectangle.top,
          )) {
            expect(peer.height, rectangle.height);
            expect(peer.width, closeTo(rectangle.width, 0.001));
          }
        }
        await tester.tap(find.text('呆滞品项 (≥90天无消耗)'));
        expect(taps, 1);
      });
    }
  }

  for (final layout in [
    (width: 1000.0, itemWidth: 156.0, rows: [5]),
    (width: 1000.0, itemWidth: 210.0, rows: [3, 2]),
    (width: 360.0, itemWidth: 156.0, rows: [2, 2, 1]),
  ]) {
    testWidgets(
      'metrics balance ${layout.rows} at width ${layout.width} with minimum ${layout.itemWidth}',
      (tester) async {
        tester.view.physicalSize = Size(layout.width, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: MetricFilterCards(
                  items: _items(),
                  itemWidth: layout.itemWidth,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final cards = find.byType(InkWell);
        final rectangles = [
          for (var index = 0; index < 5; index++)
            tester.getRect(cards.at(index)),
        ];
        final rows = <double, int>{};
        for (final rectangle in rectangles) {
          rows.update(rectangle.top, (count) => count + 1, ifAbsent: () => 1);
          expect(rectangle.width, closeTo(rectangles.first.width, 0.001));
          expect(rectangle.height, closeTo(rectangles.first.height, 0.001));
          expect(rectangle.left, greaterThanOrEqualTo(0));
          expect(rectangle.right, lessThanOrEqualTo(layout.width));
        }
        expect(rows.values, layout.rows);
      },
    );
  }
}

List<MetricFilterCardItem> _items({VoidCallback? onTap}) => [
  MetricFilterCardItem(
    key: 'dead',
    label: '呆滞品项 (≥90天无消耗)',
    value: 7,
    onTap: onTap,
  ),
  const MetricFilterCardItem(
    key: 'aged',
    label: '库龄超180天 (占库存数量%)',
    value: 18.3,
  ),
  const MetricFilterCardItem(key: 'cycle', label: '今日建议盘点', value: 3),
  const MetricFilterCardItem(
    key: 'alert',
    label: '近30天称重异常',
    value: 5,
    description: '来料少数 3 / 领料超发 2',
  ),
  const MetricFilterCardItem(key: 'sample', label: '待称样货品', value: 11),
];
