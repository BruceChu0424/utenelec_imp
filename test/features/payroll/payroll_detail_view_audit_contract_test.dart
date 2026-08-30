import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'payroll view receipt waits for detail and never reloads the detail',
    () {
      final page = File(
        'lib/features/payroll/pages/payroll_slip_detail_page.dart',
      ).readAsStringSync();
      final providers = File(
        'lib/features/payroll/providers/payroll_providers.dart',
      ).readAsStringSync();

      expect(page, contains('bool _markViewedRequested = false;'));
      expect(page, contains('data: (slip) {'));
      expect(
        page.indexOf('_markViewedRequested = true;'),
        lessThan(page.indexOf('addPostFrameCallback((_) => _markViewed())')),
      );

      final markViewedStart = providers.indexOf(
        'Future<void> markPayrollViewed',
      );
      final downloadStart = providers.indexOf(
        'Future<Uint8List> downloadPayrollSlip',
      );
      expect(markViewedStart, greaterThanOrEqualTo(0));
      expect(downloadStart, greaterThan(markViewedStart));
      final markViewedBody = providers.substring(
        markViewedStart,
        downloadStart,
      );
      expect(markViewedBody, isNot(contains('payrollDetailProvider')));
      expect(markViewedBody, contains('ref.invalidate(payrollListProvider);'));
    },
  );
}
