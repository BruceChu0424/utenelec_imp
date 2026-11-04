import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/formatters/numeric_input_evidence.dart';

void main() {
  test(
    'original and recorded decimals stay complete while the owning field controls disclosure',
    () {
      const raw = '123456789012345678901234567890.123456789012345678901234567';
      final values = <Map<String, dynamic>>[
        {
          'fieldKey': 'WEIGHT_KG',
          'originalDecimal': raw,
          'originalUnit': {'kind': 'MASS', 'code': 'KG'},
          'recordedDecimal':
              '123456789012345678901234567890.123456789012345678901234',
          'recordedUnit': {'kind': 'MASS', 'code': 'KG'},
          'usedPolicy': {
            'weight.kg-field': {'scale': 24, 'rounding': 'DOWN'},
          },
          'actorId': 'private-actor',
          'requestId': 'private-request',
        },
        {
          'fieldKey': 'PRICE',
          'originalDecimal': '991.123456789',
          'recordedDecimal': '991',
          'originalUnit': {'code': 'USD'},
          'recordedUnit': {'code': 'USD'},
        },
      ];
      final text = numericInputEvidenceTooltip(values, 'WEIGHT_KG')!;
      expect(
        text,
        contains(
          '123,456,789,012,345,678,901,234,567,890.123456789012345678901234567 kg',
        ),
      );
      expect(
        text,
        contains(
          '实际记录：123,456,789,012,345,678,901,234,567,890.123456789012345678901234 kg',
        ),
      );
      expect(text, contains('保留24位，直接截取，不进位'));
      expect(text, isNot(contains('991')));
      expect(text, isNot(contains('private-')));
      expect(numericInputEvidenceTooltip(values, 'COUNT_WEIGHT_KG'), isNull);
    },
  );
}
