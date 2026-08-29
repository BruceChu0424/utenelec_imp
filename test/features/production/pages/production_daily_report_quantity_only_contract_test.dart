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
    expect(detail, contains("label: '完工申报量'"));
    expect(detail, contains('生成生产成品质检任务'));
    expect(detail, isNot(contains('并生成成品入库草稿')));
    expect(edit, contains("'fqcRecoveryAuthorizationId'"));
    expect(columns, contains('返工再检'));
    expect(edit, isNot(contains('不良品隔离、返工和补产链路')));
    expect(service, contains('line.getPrice() != null'));
    expect(service, contains('客户端单价/金额不是计件工资依据，已停止写入'));
  });
}
