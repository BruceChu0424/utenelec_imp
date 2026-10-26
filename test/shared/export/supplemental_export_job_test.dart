import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/export/report_export_jobs.dart';
import 'package:uten_imp/shared/export/supplemental_export_job.dart';

void main() {
  test(
    'audit modes retain the original selected table and full string snapshot ID',
    () {
      expect(reportExportJobDomain('/admin/audit-logs/export'), 'audit');
      expect(
        supplementalExportJobReport(
          'audit',
          'features.admin.pages.audit_overview_widgets.AuditSessionTable.build.1',
        ),
        'sessions',
      );
      expect(supplementalExportJobReport('audit', null), 'activity');
      final result = supplementalExportJobParameters('audit', {
        'snapshotId': '9007199254740993',
        'activityOnly': false,
        'actorId': null,
        'password': 'never-store',
      }, {});
      expect(result, {
        'snapshotId': '9007199254740993',
        'activityOnly': 'false',
      });
    },
  );
  test(
    'actual-cost private body preserves its original digest and query without passwords or null text',
    () {
      expect(
        reportExportJobDomain('/master/goods/cost-sheets/actual/export'),
        'goods_actual_cost',
      );
      expect(
        supplementalExportJobReport('goods_actual_cost', null),
        'snapshot',
      );
      final result = supplementalExportJobParameters('goods_actual_cost', {}, {
        'goodsId': 'source-good',
        'from': '2026-10-01',
        'expectedDigest': 'a' * 64,
        'revisionId': null,
        'format': 'pdf',
        'password': 'never-store',
      });
      expect(result, {
        'goodsId': 'source-good',
        'from': '2026-10-01',
        'expectedDigest': 'a' * 64,
      });
      expect(
        () => supplementalExportJobParameters('goods_actual_cost', {}, {
          'goodsId': {'forged': 'object'},
        }),
        throwsFormatException,
      );
    },
  );
}
