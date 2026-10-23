@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/core/print/isolated_print_pdf_native.dart';
import 'package:uten_imp/core/print/print_pdf_document.dart';

void main() {
  for (final duringSpawn in [true, false]) {
    test(
      'dispose kills the actual PDF isolate ${duringSpawn ? 'during spawn' : 'after start'}',
      () async {
        final exit = ReceivePort();
        addTearDown(exit.close);
        final started = Completer<void>();
        final generator = IsolatedPrintPdfGenerator(
          debugOnIsolateStarted: (isolate) {
            isolate.addOnExitListener(exit.sendPort, response: 'terminated');
            started.complete();
          },
        );
        addTearDown(generator.dispose);
        final future = generator.generate(
          PrintPdfRequest(
            title: 'cancel',
            headers: const ['Item', 'Amount'],
            rows: [
              for (var i = 0; i < 20000; i++) ['item-$i', '$i.12345678'],
            ],
          ),
        );
        final refused = expectLater(future, throwsA(isA<UiWorkCancelled>()));
        if (!duringSpawn) await started.future;
        generator.dispose();
        await started.future;
        expect(
          await exit.first.timeout(const Duration(seconds: 2)),
          'terminated',
        );
        await refused;
        await expectLater(
          generator.generate(
            const PrintPdfRequest(title: 'later', headers: ['Item'], rows: []),
          ),
          throwsA(isA<UiWorkCancelled>()),
        );
      },
    );
  }
}
