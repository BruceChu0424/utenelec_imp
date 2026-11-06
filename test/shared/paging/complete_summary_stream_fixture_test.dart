@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/paging/complete_summary_stream.dart';
import 'package:uten_imp/shared/paging/versioned_summary_read.dart';

void main() {
  final contract =
      jsonDecode(
            File(
              'contracts/complete-summary-stream-v1.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final rawCase in contract['cases'] as List) {
    final source = rawCase as Map<String, dynamic>;
    test('shared Dart/C# fixture ${source['name']}', () async {
      final frames = (source['frames'] as List).cast<Map<String, dynamic>>();
      final stream = CompleteSummaryStream(Stream.fromIterable(frames));
      Future<VersionedSummarySnapshot<Map<String, dynamic>>> read() async {
        try {
          return await readVersionedSummarySnapshot<Map<String, dynamic>>(
            loadPage: stream.page,
            isCurrent: () => true,
            decode: (row) => row,
            idOf: (row) => row['id'],
          );
        } finally {
          await stream.close();
        }
      }

      final pending = read();
      if (source['expected'] == 'success') {
        final rows = (await pending).items;
        expect(rows, hasLength(1));
        expect(rows.single['name'], '货品原文');
        expect(
          rows.single['stockQtyDisplayText'],
          '90071992547409.123456789012345678900',
        );
        expect(rows.single['priceDisplayText'], '12.3400');
        expect(rows.single['writable'], isFalse);
      } else {
        await expectLater(
          pending,
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              source['expected'],
            ),
          ),
        );
      }
    });
  }
}
