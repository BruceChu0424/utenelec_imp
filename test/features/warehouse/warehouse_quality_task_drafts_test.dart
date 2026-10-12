import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_form_drafts.dart';
import 'package:uten_imp/features/quality/models/quality_task_form_drafts.dart';
import 'package:uten_imp/shared/drafts/form_draft_catalog.dart';

FormDraft _draft(
  String id,
  FormDraftDescriptor descriptor, {
  String? route,
  Map<String, dynamic> data = const {},
}) {
  final spec = descriptor.spec(route: route);
  return FormDraft(
    id: id,
    title: id,
    module: spec.module,
    route: spec.route,
    permission: spec.permission,
    draftKind: spec.draftKind,
    data: data,
    updatedAt: DateTime.utc(2026, 10, 11),
  );
}

void main() {
  test(
    'quality receipt types restore case-insensitively without crossing source types',
    () {
      final iqc = _draft(
        'iqc-lower',
        FormDraftCatalog.iqcReport,
        route: '/warehouse/inspections/purchase/r-1',
      );
      final stockIn = _draft(
        'stock-in-lower',
        FormDraftCatalog.warehouseQualityStockIn,
        route: '/warehouse/quality-results/purchase/r-1',
      );
      final preStockIn = _draft(
        'pre-stock-in-lower',
        FormDraftCatalog.warehouseQualityPreStockIn,
        route: '${RouteName.warehouseQualityPreStockInBase}/subcontract/r-2',
      );
      final batch = _draft(
        'stock-batch-lower',
        FormDraftCatalog.warehouseQualityBatchStockIn,
        route:
            '${RouteName.warehouseQualityBatchStockIn}?receipts=purchase:r-1,subcontract:r-2',
        data: {
          'receipts': [
            {'receiptType': 'purchase', 'receiptId': 'r-3'},
          ],
        },
      );
      expect(
        qualityTaskDrafts([iqc], receiptType: 'PURCHASE', receiptId: 'r-1'),
        [iqc],
      );
      expect(qualityStockInTaskDrafts([stockIn], 'PURCHASE', 'r-1'), [stockIn]);
      expect(qualityStockInTaskDrafts([preStockIn], 'SUBCONTRACT', 'r-2'), [
        preStockIn,
      ]);
      expect(qualityStockInTaskDrafts([batch], 'PURCHASE', 'r-1'), [batch]);
      expect(qualityStockInTaskDrafts([batch], 'SUBCONTRACT', 'r-2'), [batch]);
      expect(qualityStockInTaskDrafts([batch], 'PURCHASE', 'r-3'), [batch]);
      expect(
        qualityStockInTaskDrafts(
          [stockIn, preStockIn, batch],
          'SUBCONTRACT',
          'r-1',
        ),
        isEmpty,
      );
      expect(
        qualityTaskDrafts([iqc], receiptType: 'SUBCONTRACT', receiptId: 'r-1'),
        isEmpty,
      );
    },
  );
  test(
    'arrival batch resumes from each exact source and ignores unrelated UUIDs',
    () {
      final draft = _draft(
        'arrival',
        FormDraftCatalog.arrival,
        route:
            '${RouteName.warehouseArrivalRegistration}?expectationIds=e-1,e-10',
        data: {
          'warehouseId': 'e-2',
          'rows': [
            {'expectationId': 'e-1', 'goodsId': 'e-3'},
            {'expectationId': 'e-10'},
          ],
        },
      );
      expect(arrivalTaskDrafts([draft], 'e-1'), [draft]);
      expect(arrivalTaskDrafts([draft], 'e-10'), [draft]);
      expect(arrivalTaskDrafts([draft], 'e-2'), isEmpty);
      expect(arrivalTaskDrafts([draft], 'e-3'), isEmpty);
    },
  );
  test('source UUID alone does not grant a different editor permission', () {
    final draft = _draft(
      'arrival',
      FormDraftCatalog.arrival,
      route: '${RouteName.warehouseArrivalRegistration}?expectationIds=e-1',
    );
    final impostor = FormDraft(
      id: 'wrong',
      title: '',
      module: draft.module,
      route: draft.route,
      permission: '',
      data: draft.data,
      updatedAt: draft.updatedAt,
    );
    expect(arrivalTaskDrafts([impostor], 'e-1'), isEmpty);
  });
  test(
    'IQC batch matches receipt type and id, never supplier or goods identity',
    () {
      final draft = _draft(
        'iqc-batch',
        FormDraftCatalog.iqcBatchReport,
        data: {
          'selection': {
            'receipts': [
              {
                'receiptType': 'PURCHASE',
                'receiptId': 'receipt-1',
                'supplierId': 'receipt-2',
              },
              {'receiptType': 'SUBCONTRACT', 'receiptId': 'receipt-3'},
            ],
          },
        },
      );
      expect(
        qualityTaskDrafts(
          [draft],
          receiptType: 'PURCHASE',
          receiptId: 'receipt-1',
        ),
        [draft],
      );
      expect(
        qualityTaskDrafts(
          [draft],
          receiptType: 'SUBCONTRACT',
          receiptId: 'receipt-1',
        ),
        isEmpty,
      );
      expect(
        qualityTaskDrafts(
          [draft],
          receiptType: 'PURCHASE',
          receiptId: 'receipt-2',
        ),
        isEmpty,
      );
      expect(
        qualityTaskDrafts(
          [draft],
          receiptType: 'SUBCONTRACT',
          receiptId: 'receipt-3',
        ),
        [draft],
      );
    },
  );
  test(
    'FQC single, sheet and batch identities all attach to the original task',
    () {
      final sheet = _draft(
        'sheet',
        FormDraftCatalog.fqcSheet,
        route: RouteName.productionFqcSheetHandling('sheet-1'),
      );
      final single = _draft(
        'inspection',
        FormDraftCatalog.fqcInspection,
        route: RouteName.productionFqcInspectionHandling('inspection-1'),
      );
      final batch = _draft(
        'batch',
        FormDraftCatalog.fqcBatchReport,
        data: {
          'selection': {
            'sheetIds': ['sheet-1'],
            'inspectionIds': ['inspection-1'],
          },
        },
      );
      expect(
        qualityTaskDrafts([
          sheet,
          single,
          batch,
        ], sheetId: 'sheet-1').map((draft) => draft.id).toSet(),
        {'sheet', 'batch'},
      );
      expect(
        qualityTaskDrafts([
          sheet,
          single,
          batch,
        ], inspectionId: 'inspection-1').map((draft) => draft.id).toSet(),
        {'inspection', 'batch'},
      );
    },
  );
  test(
    'confirmed subcontract members do not keep a completed task marked draft',
    () {
      final batch = _draft(
        'sub-batch',
        FormDraftCatalog.subcontractOutboundBatch,
        route: '/warehouse/subcontract-outbound/batch?issueIds=issue-1,issue-2',
        data: {
          'completed': ['issue-1'],
        },
      );
      expect(subcontractOutboundTaskDrafts([batch], 'issue-1'), isEmpty);
      expect(subcontractOutboundTaskDrafts([batch], 'issue-2'), [batch]);
    },
  );
  test(
    'sales batch input stays attached only to unfinished source shipments',
    () {
      final batch = _draft(
        'sales-batch',
        FormDraftCatalog.warehouseSalesOutboundBatch,
        route: '/warehouse/sales-outbound/batch?shipmentIds=s-1,s-2',
        data: {
          'completed': ['s-1'],
        },
      );
      expect(salesOutboundTaskDrafts([batch], 's-1'), isEmpty);
      expect(salesOutboundTaskDrafts([batch], 's-2'), [batch]);
    },
  );
  test(
    'warehouse quality stock-in batches match typed receipts, separate from IQC editor',
    () {
      final batch = _draft(
        'putaway',
        FormDraftCatalog.warehouseQualityBatchStockIn,
        route:
            '${RouteName.warehouseQualityBatchStockIn}?receipts=PURCHASE:r-1,SUBCONTRACT:r-2',
        data: {
          'receipts': [
            {'receiptType': 'PURCHASE', 'receiptId': 'r-1'},
          ],
        },
      );
      expect(qualityStockInTaskDrafts([batch], 'PURCHASE', 'r-1'), [batch]);
      expect(qualityStockInTaskDrafts([batch], 'SUBCONTRACT', 'r-2'), [batch]);
      expect(qualityStockInTaskDrafts([batch], 'SUBCONTRACT', 'r-1'), isEmpty);
      expect(
        qualityTaskDrafts([batch], receiptType: 'PURCHASE', receiptId: 'r-1'),
        isEmpty,
      );
    },
  );
}
