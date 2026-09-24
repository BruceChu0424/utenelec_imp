import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_revision_table.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/sales/widgets/shipment_finance_change_summary.dart';

String _snapshot(
  List<Map<String, dynamic>> items, {
  Map<String, dynamic> header = const {},
}) => jsonEncode({'header': header, 'items': items});

void main() {
  test(
    'renumbering after deletion and decimal scale changes keep surviving rows neutral',
    () {
      final rows = shipmentFinanceRevisionRows(
        _snapshot([
          {'id': 'deleted', 'lineNo': 1, 'goodsId': 'old', 'qty': '1'},
          {
            'id': 'kept',
            'lineNo': 2,
            'goodsId': 'same',
            'qty': '10.0000',
            'clientNo': '0010',
          },
        ]),
        _snapshot([
          {
            'id': 'kept',
            'lineNo': 1,
            'goodsId': 'same',
            'qty': '10',
            'clientNo': '0010',
          },
        ]),
      );
      expect(rows.map((row) => row.kind), [
        UtenRevisionKind.removed,
        UtenRevisionKind.unchanged,
      ]);
      expect(rows[1].value['lineNo'], 1);
      expect(rows[1].value['clientNo'], '0010');
    },
  );

  test(
    'quantity-only revision repeats the full item below the removed row',
    () {
      final before = {
        'id': 'row',
        'goodsId': 'goods',
        'lineNo': 1,
        'price': '1234567890123.4567',
        'qty': '2.0000',
        'remark': '保留备注',
      };
      final rows = shipmentFinanceRevisionRows(
        _snapshot([before]),
        _snapshot([
          {...before, 'qty': '3.0000'},
        ]),
      );
      expect(rows.map((row) => row.kind), [
        UtenRevisionKind.removed,
        UtenRevisionKind.added,
      ]);
      expect(rows[0].value, before);
      expect(rows[1].value['qty'], '3.0000');
      expect(rows[1].value['price'], '1234567890123.4567');
      expect(rows[1].value['remark'], '保留备注');
    },
  );

  test(
    'duplicate goods remain distinct; deletion, unchanged and added rows retain their order',
    () {
      final removed = {'id': 'one', 'goodsId': 'same', 'lineNo': 1, 'qty': '2'};
      final unchanged = {
        'id': 'two',
        'goodsId': 'same',
        'lineNo': 2,
        'qty': '3',
      };
      final added = {'id': 'three', 'goodsId': 'new', 'lineNo': 3, 'qty': '4'};
      final rows = shipmentFinanceRevisionRows(
        _snapshot([removed, unchanged]),
        _snapshot([unchanged, added]),
      );
      expect(rows.map((row) => row.kind), [
        UtenRevisionKind.removed,
        UtenRevisionKind.unchanged,
        UtenRevisionKind.added,
      ]);
      expect(rows.map((row) => row.value['id']), ['one', 'two', 'three']);
      expect(rows.map((row) => row.label), ['已删除', null, '新增']);
    },
  );

  testWidgets(
    'item diff is a complete table, while the top contains only changed header fields',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final old = _snapshot(
        [
          {
            'id': 'row',
            'lineNo': 1,
            'goodsId': '货品 A',
            'price': '1234567890123.4567',
            'qty': '2.0000',
          },
        ],
        header: {'shipAddr': '原地址'},
      );
      final now = _snapshot(
        [
          {
            'id': 'row',
            'lineNo': 1,
            'goodsId': '货品 A',
            'price': '1234567890123.4568',
            'qty': '3.0000',
          },
        ],
        header: {'shipAddr': '新地址'},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ShipmentFinanceChangeSummary(previous: old, current: now),
                Expanded(
                  child: ShipmentFinanceChangeTable(
                    previous: old,
                    current: now,
                    embedded: false,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final table = tester.widget<UtenRevisionTable<Map<String, dynamic>>>(
        find.byType(UtenRevisionTable<Map<String, dynamic>>),
      );
      expect(table.rows, hasLength(2));
      final price = table.columns.singleWhere(
        (column) => column.key == 'price',
      );
      expect(price.value(table.rows[0].value), '1234567890123.4567');
      expect(price.value(table.rows[1].value), '1234567890123.4568');
      expect(table.rows[1].changedKeys, containsAll(['qty', 'price']));
      expect(table.rows[1].changedKeys, isNot(contains('goodsId')));
      final changedQuantity = tester.widget<Text>(find.text('3.0000'));
      expect(changedQuantity.style?.fontWeight, FontWeight.w800);
      expect(changedQuantity.style?.color, UtenColors.errorText);
      expect(
        DefaultTextStyle.of(tester.element(find.text('货品 A').last)).style.color,
        UtenColors.successText,
      );
      expect(find.text('原地址'), findsOneWidget);
      expect(find.text('新地址'), findsOneWidget);
      expect(find.textContaining('以前：'), findsNothing);
      expect(find.byType(UtenRevisionStrike), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'unreadable or ambiguous identities are not accepted as review snapshots',
    () {
      expect(readableShipmentReviewSnapshot(null), isFalse);
      expect(readableShipmentReviewSnapshot('{broken'), isFalse);
      expect(
        readableShipmentReviewSnapshot('{"header":{},"items":[]}'),
        isTrue,
      );
      expect(
        readableShipmentReviewSnapshot(
          _snapshot([
            {'id': 'same'},
            {'id': 'same'},
          ]),
        ),
        isFalse,
      );
      expect(
        readableShipmentReviewSnapshot(
          _snapshot([
            {'goodsId': 'missing-id'},
          ]),
        ),
        isFalse,
      );
    },
  );
}
