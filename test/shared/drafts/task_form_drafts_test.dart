import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/badges/effective_badge_summary_provider.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/drafts/form_draft_catalog.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/drafts/task_form_drafts.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_form_drafts.dart';

FormDraft _draft(
  FormDraftSpec spec, {
  String id = 'local',
  Map<String, dynamic> data = const {},
}) => FormDraft(
  id: id,
  title: spec.title,
  module: spec.module,
  route: spec.route,
  permission: spec.permission,
  draftKind: spec.draftKind,
  updatedAt: DateTime.utc(2026, 10, 11),
  data: data,
);

void main() {
  test(
    'finished arrival drafts match the selected lot within the source report',
    () {
      final scoped = _draft(
        FormDraftCatalog.finishedArrival.spec(
          route:
              '/warehouse/production-finished-in/arrival-registrations?reportIds=report-a&lotIds=lot-a',
        ),
      );
      expect(
        finishedInboundTaskDrafts(
          [scoped],
          reportId: 'report-a',
          lotId: 'lot-a',
        ),
        [scoped],
      );
      expect(
        finishedInboundTaskDrafts(
          [scoped],
          reportId: 'report-a',
          lotId: 'lot-b',
        ),
        isEmpty,
      );
      final legacy = _draft(
        FormDraftCatalog.finishedArrival.spec(
          route:
              '/warehouse/production-finished-in/arrival-registrations?reportIds=report-a',
        ),
        data: {
          'rows': [
            {'lotId': 'lot-a'},
          ],
        },
      );
      expect(
        finishedInboundTaskDrafts(
          [legacy],
          reportId: 'report-a',
          lotId: 'lot-a',
        ),
        [legacy],
      );
      expect(
        finishedInboundTaskDrafts(
          [legacy],
          reportId: 'report-a',
          lotId: 'lot-b',
        ),
        isEmpty,
      );
    },
  );

  test(
    'old task permission labels cannot create a second todo or authorize restore',
    () {
      final current = FormDraftCatalog.warehouseSalesOutbound.spec(
        route: '/warehouse/sales-outbound/shipment-a',
      );
      final checkpoint = FormDraft(
        id: 'old-task',
        title: current.title,
        module: current.module,
        route: current.route,
        permission: 'retired_warehouse_issue:edit',
        updatedAt: DateTime.utc(2026, 10, 12),
        data: const {},
      );
      expect(
        FormDraftCatalog.warehouseSalesOutbound.groups(checkpoint),
        isFalse,
      );
      expect(isTaskFormDraft(checkpoint), isTrue);
      expect(
        includeFormDraftBadges(BadgeSummary.empty, [checkpoint]).total.todo,
        0,
      );
    },
  );

  test(
    'task checkpoints stay out of standalone draft counts without adding a second todo',
    () {
      final task = _draft(
        FormDraftCatalog.arrival.spec(
          route:
              '/warehouse/inbound/arrivals/register?expectationIds=source-a,source-b',
        ),
      );
      final document = _draft(
        FormDraftCatalog.stockDocument.spec(route: '/warehouse/OTHER_IN/new'),
        id: 'new-document',
      );
      const scope = FormDraftCategoryScope(
        module: BadgeModule.warehouse,
        excludeTaskDrafts: true,
      );
      expect(scope.matches(task), isFalse);
      expect(scope.matches(document), isTrue);
      const server = BadgeSummary.empty;
      final projected = includeFormDraftBadges(server, [task, document]);
      expect(projected.total.todo, server.total.todo + 1);
      expect(projected.entries[BadgeEntry.warehouseDrafts.name]?.todo, 1);
    },
  );

  test(
    'standalone report creation retains its draft while workshop report overlays a task',
    () {
      final standalone = _draft(
        FormDraftCatalog.dailyReport.spec(),
        data: {
          'rows': [
            {'executionSegmentId': 'segment-a'},
          ],
        },
      );
      final workshop = _draft(
        FormDraftCatalog.dailyReport.spec(
          route:
              '/production/daily-reports/new?from=workshop-tasks&executionSegmentIds=segment-a',
        ),
      );
      expect(isTaskFormDraft(standalone), isFalse);
      expect(isTaskFormDraft(workshop), isTrue);
      final unboundReturn = _draft(
        FormDraftCatalog.productionReturn.spec(
          route: '/production/material-return/new?planId=plan-a',
        ),
      );
      expect(
        isTaskFormDraft(unboundReturn),
        isFalse,
        reason: 'a whole-plan return needs its existing recovery entry',
      );
    },
  );

  test(
    'IQC, FQC and warehouse task editors use their reviewed catalog routes',
    () {
      for (final spec in [
        FormDraftCatalog.iqcReport.spec(
          route: '/warehouse/inspections/PURCHASE/receipt-a',
        ),
        FormDraftCatalog.fqcSheet.spec(
          route: '/warehouse/inspections/fqc/sheets/sheet-a',
        ),
        FormDraftCatalog.fqcInspection.spec(
          route: '/warehouse/inspections/fqc/inspections/inspection-a',
        ),
        FormDraftCatalog.subcontractOutboundBatch.spec(
          route: '/warehouse/subcontract-outbound/batch?issueIds=issue-a',
        ),
        FormDraftCatalog.warehouseQualityPreStockIn.spec(
          route: '/warehouse/quality-results/pre-stock-in/PURCHASE/receipt-a',
        ),
        FormDraftCatalog.warehouseQualityBatchStockIn.spec(
          route:
              '/warehouse/quality-results/batch-stock-in?receipts=PURCHASE:receipt-a',
        ),
        FormDraftCatalog.warehouseSalesOutboundBatch.spec(
          route: '/warehouse/sales-outbound/batch?shipmentIds=shipment-a',
        ),
        FormDraftCatalog.materialReturnBatchReceive.spec(
          route:
              '/warehouse/material-returns/batch-receive?documentIds=return-a',
        ),
      ]) {
        expect(isTaskFormDraft(_draft(spec)), isTrue, reason: spec.route);
      }
      expect(
        isTaskFormDraft(_draft(FormDraftCatalog.stockCount.spec())),
        isFalse,
      );
    },
  );

  test(
    'explicit task matching deduplicates a batch snapshot and distinguishes an uncertain send',
    () {
      final batch = _draft(
        FormDraftCatalog.arrival.spec(
          route: '/warehouse/inbound/arrivals/register?expectationIds=a,b',
        ),
        data: {'_formDraftHasUnknownSubmission': true},
      );
      final other = _draft(
        FormDraftCatalog.arrival.spec(
          route: '/warehouse/inbound/arrivals/register?expectationIds=c',
        ),
        id: 'other',
      );
      final result = taskDraftsFor(
        [batch, other, batch],
        matches: (draft) => Uri.parse(
          draft.route,
        ).queryParameters['expectationIds']!.split(',').contains('a'),
      );
      expect(result, [batch]);
      expect(taskDraftStatus(result), '提交待核对');
      expect(taskDraftStatus([other]), '草稿');
      expect(batch.resumeLocation, contains('draftId=local'));
    },
  );
}
