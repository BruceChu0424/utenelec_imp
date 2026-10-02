import 'dart:io';
import 'package:flutter/services.dart';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_cell_revision_table.dart';
import 'package:uten_imp/components/data_display/uten_revision_table.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/sales/widgets/sales_quote_revision_comparison.dart';

void main() {
  setUpAll(() async {
    final file = File('C:/Windows/Fonts/msyh.ttc');
    if (await file.exists()) {
      final loader = FontLoader('QuoteVisualTest')
        ..addFont(
          file.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await loader.load();
    }
  });
  test(
    'same goods on multiple lines matches line id; unchanged decimal scale is not a change',
    () {
      final rows = salesQuoteRevisionRows(
        {
          'lines': [
            {'id': 'a', 'goodsId': 'g', 'price': '10.00', 'qty': '2'},
            {'id': 'b', 'goodsId': 'g', 'price': '20', 'qty': '3'},
            {'id': 'deleted', 'goodsId': 'g', 'price': '5', 'qty': '1'},
          ],
        },
        {
          'lines': [
            {'id': 'b', 'goodsId': 'g', 'price': '21', 'qty': '3'},
            {'id': 'a', 'goodsId': 'g', 'price': '10', 'qty': '2.000'},
            {'id': 'new', 'goodsId': 'g', 'price': '8', 'qty': '1'},
          ],
        },
      );
      expect(rows, hasLength(4));
      expect(rows[0].changedKeys, isEmpty);
      expect(rows[1].changedKeys, {'price'});
      expect(rows[2].removed, isTrue);
      expect(rows[3].added, isTrue);
    },
  );

  testWidgets(
    'only the changed old cell is struck; new-price column is red; true deletion strikes the row',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('quote-revision-capture'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: 'QuoteVisualTest'),
            home: Scaffold(
              body: SizedBox(
                height: 500,
                child: UtenCellRevisionTable<Map<String, String>>(
                  columns: [
                    MasterColumnDef(
                      key: 'name',
                      label: '货品名称',
                      width: 180,
                      value: (r) => r['name'],
                    ),
                    MasterColumnDef(
                      key: 'price',
                      label: '单价',
                      width: 120,
                      value: (r) => r['price'],
                    ),
                  ],
                  rows: const [
                    UtenCellRevisionRow(
                      before: {'name': '开关', 'price': '10'},
                      after: {'name': '开关', 'price': '12'},
                      changedKeys: {'price'},
                    ),
                    UtenCellRevisionRow(before: {'name': '插座', 'price': '25'}),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('新单价'), findsOneWidget);
      expect(find.text('新货品名称'), findsNothing);
      final oldPrice = tester.widget<Text>(find.text('10'));
      final newPrice = tester.widget<Text>(find.text('12'));
      expect(oldPrice.style?.decoration, TextDecoration.lineThrough);
      expect(newPrice.style?.color, oldPrice.style?.color);
      expect(
        tester.widget<Text>(find.text('开关')).style?.decoration,
        isNot(TextDecoration.lineThrough),
      );
      expect(find.byType(UtenRevisionStrike), findsOneWidget);
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('quote-revision-capture')),
      );
      await tester.runAsync(() async {
        final pixels = await boundary.toImage();
        final bytes = await pixels.toByteData(format: ui.ImageByteFormat.png);
        final destination = File('build/quote-cell-revision-desktop.png');
        await destination.parent.create(recursive: true);
        await destination.writeAsBytes(bytes!.buffer.asUint8List());
        pixels.dispose();
      });
    },
  );
}
