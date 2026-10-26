@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'bundled CSP worker matches the reviewed renderer and locked dependencies',
    () {
      final receipt =
          jsonDecode(
                File(
                  'assets/workers/uten_pdf_worker.build.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(receipt['sourceTextNormalization'], 'LF');
      expect(receipt['flags'], contains('--csp'));
      expect(receipt['supportedProtocolVersions'], [1, 2, 3]);
      final sources = Map<String, String>.from(receipt['sources'] as Map);
      expect(
        sources.keys,
        containsAll([
          'tool/pdf_worker.dart',
          'lib/core/print/print_pdf_document.dart',
          'lib/core/performance/ui_work_budget.dart',
          'lib/features/purchase/models/purchase_order_pdf_bundle.dart',
          'lib/features/purchase/models/purchase_order_pdf.dart',
          'pubspec.lock',
        ]),
      );
      for (final entry in sources.entries) {
        final text = File(
          entry.key,
        ).readAsStringSync().replaceAll('\r\n', '\n');
        expect(
          sha256.convert(utf8.encode(text)).toString(),
          entry.value,
          reason: '${entry.key} changed; run python tool/build_pdf_worker.py',
        );
      }
      final bytes = File('assets/workers/uten_pdf_worker.js').readAsBytesSync();
      expect(bytes.length, receipt['workerBytes']);
      expect(sha256.convert(bytes).toString(), receipt['workerSha256']);
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('- assets/workers/uten_pdf_worker.js'),
      );
    },
  );
}
