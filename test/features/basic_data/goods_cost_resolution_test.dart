import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_cost_sheet.dart';

Map<String, dynamic> column(
  String key, {
  String type = 'PER_QUANTITY',
  String? name,
}) => {
  'key': key,
  'name': name ?? key,
  'type': type,
  'category': 'PROCESS',
  'baseKeys': ['MATERIAL'],
};
Map<String, dynamic> input() => {
  'goodsId': 'goods',
  'clientId': 'client',
  'batchQty': '0.000007123456',
  'lineOverrides': [
    {'path': 'edge', 'adoptedQty': '0.123456789'},
  ],
  'priceColumns': [column('auto'), column('manual')],
  'priceCells': [
    {'path': 'edge', 'columnKey': 'manual', 'value': '0', 'quantity': '2'},
  ],
  'notes': 'explicit notes',
  'extraFields': {
    'costAutoPriceColumnKeys': '["auto"]',
    'importId': 'evidence',
  },
};
void main() {
  test(
    'unit-price editor never displays an unnormalized per-package or foreign override',
    () {
      final raw = {
        'unitPrice': '400',
        'priceUnitRate': '25',
        'priceExchangeRateToLocal': '1',
        'priceSourceType': 'MANUAL',
        'taxMode': 'AS_RECORDED',
      };
      expect(costUnitPriceEditorText({'unitPrice': '16'}, raw, '1'), '16');
      final normalized = {...raw, 'unitPrice': '20.0000', 'priceUnitRate': '1'};
      expect(
        costUnitPriceEditorText({'unitPrice': '20'}, normalized, '1.000'),
        '20.0000',
      );
      expect(
        costUnitPriceEditorText({'unitPrice': '2.5'}, normalized, '8'),
        '2.5',
      );
      expect(
        costUnitPriceEditorText(
          {'unitPrice': '17.7'},
          {...normalized, 'taxMode': 'EXCLUDE_TAX'},
          '1',
        ),
        '17.7',
      );
      expect(positiveCostRate(null), isFalse);
      expect(positiveCostRate('0'), isFalse);
      expect(positiveCostRate('-1'), isFalse);
      expect(positiveCostRate('0.000001'), isTrue);
    },
  );
  test(
    'old Calculation responses without resolved input retain the existing contract',
    () {
      final calculation = GoodsCostCalculation({
        'lines': <Object>[],
        'fees': <Object>[],
        'totals': {
          'knownTotal': '1.123456789123456789',
          'valueState': 'COMPLETE',
        },
      });
      expect(calculation.resolvedInput, isNull);
      expect(calculation.totals['knownTotal'], '1.123456789123456789');
      expect(
        mergeResolvedCostInput(input(), calculation.resolvedInput),
        input(),
      );
    },
  );
  test(
    'resolved suggestions update only automatic definitions and approved metadata',
    () {
      final current = input();
      final merged = mergeResolvedCostInput(current, {
        ...current,
        'batchQty': '999',
        'lineOverrides': <Object>[],
        'priceCells': <Object>[],
        'notes': 'server default',
        'priceColumns': [
          column('auto', name: 'new template label'),
          column('manual', type: 'PERCENT'),
          column('new'),
        ],
        'extraFields': {
          'costAutoPriceColumnKeys': '["auto","manual","new"]',
          'costTemplateVersions': '{"t":2}',
          'serverClientName': 'snapshot client',
        },
      });
      expect(merged['batchQty'], current['batchQty']);
      expect(merged['lineOverrides'], current['lineOverrides']);
      expect(merged['priceCells'], current['priceCells']);
      expect(merged['notes'], current['notes']);
      final columns = {
        for (final c in costMaps(merged['priceColumns'])) c['key']: c,
      };
      expect(columns['auto']!['name'], 'new template label');
      expect(columns['manual']!['type'], 'PER_QUANTITY');
      expect(costMap(merged['extraFields'])['importId'], 'evidence');
      expect(
        costMap(merged['extraFields'])['serverClientName'],
        'snapshot client',
      );
      expect(
        costMetadataKeys(
          costMap(merged['extraFields'])['costAutoPriceColumnKeys'],
        ),
        {'auto', 'new'},
      );
    },
  );
  test(
    'filled automatic prices cannot become percentages after a template revision',
    () {
      final current = input()
        ..['priceCells'] = [
          {'path': 'edge', 'columnKey': 'auto', 'value': '0'},
        ];
      final merged = mergeResolvedCostInput(current, {
        ...current,
        'priceColumns': [column('auto', type: 'PERCENT')],
        'extraFields': {'costAutoPriceColumnKeys': '["auto"]'},
      });
      expect(
        costMaps(
          merged['priceColumns'],
        ).firstWhere((c) => c['key'] == 'auto')['type'],
        'PER_QUANTITY',
      );
      expect(
        costMetadataKeys(
          costMap(merged['extraFields'])['costAutoPriceColumnKeys'],
        ),
        isEmpty,
      );
      expect(merged['priceCells'], current['priceCells']);
    },
  );
  test(
    'unfilled removed suggestions disappear but explicit pending cells stay intact',
    () {
      final current = input();
      final without = mergeResolvedCostInput(current, {
        ...current,
        'priceColumns': [column('manual')],
        'extraFields': {'costAutoPriceColumnKeys': '[]'},
      });
      expect(costMaps(without['priceColumns']).map((c) => c['key']), [
        'manual',
      ]);
      current['priceCells'] = [
        {'path': 'edge', 'columnKey': 'auto', 'value': ''},
      ];
      final pending = mergeResolvedCostInput(current, {
        ...current,
        'priceColumns': <Object>[],
        'extraFields': {'costAutoPriceColumnKeys': '[]'},
      });
      expect(
        costMaps(pending['priceColumns']).map((c) => c['key']),
        contains('auto'),
      );
      expect(pending['priceCells'], current['priceCells']);
    },
  );
  test(
    'explicit column changes persist as manual and a foreign client cannot supply metadata',
    () {
      final current = input();
      final manual = markCostPriceColumnManual(current, 'auto');
      expect(
        jsonDecode(
          costMap(manual['extraFields'])['costAutoPriceColumnKeys'] as String,
        ),
        isEmpty,
      );
      expect(manual['priceCells'], current['priceCells']);
      expect(
        mergeResolvedCostInput(current, {
          ...current,
          'clientId': 'other',
          'priceColumns': <Object>[],
        }),
        current,
      );
    },
  );
}
