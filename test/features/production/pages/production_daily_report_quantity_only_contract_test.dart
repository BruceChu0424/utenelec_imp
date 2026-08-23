import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production report UI exposes quantity facts only', () {
    final detail = File(
      'lib/features/production/pages/production_daily_report_detail_page.dart',
    ).readAsStringSync();
    final edit = File(
      'lib/features/production/pages/production_daily_report_edit_page.dart',
    ).readAsStringSync();
    final columns = File(
      'lib/features/production/widgets/production_daily_grid_columns.dart',
    ).readAsStringSync();
    final service = File(
      'server/src/main/java/com/uten/imp/features/production/dailyreport/'
      'ProductionDailyReportService.java',
    ).readAsStringSync();

    for (final source in [detail, edit, columns]) {
      expect(source, isNot(contains("label: '单价'")));
      expect(source, isNot(contains("label: '金额'")));
    }
    expect(detail, contains("label: '合格完工量'"));
    expect(service, contains('line.getPrice() != null'));
    expect(service, contains('客户端单价/金额不是计件工资依据，已停止写入'));
  });
}
