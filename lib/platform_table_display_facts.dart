import 'features/basic_data/models/goods_bom_item.dart';
import 'features/finance/models/finance_asset_models.dart';
import 'features/finance/models/finance_doc.dart';
import 'features/finance/models/finance_procurement_workflow.dart';
import 'features/finance/models/sales_order_finance_confirmation.dart';
import 'features/finance/models/sales_quote_finance_review.dart';
import 'features/finance/payables/models/finance_payable.dart';
import 'features/finance/payables/models/subcontract_loss_claim.dart';
import 'features/finance/payables/models/supplier_settlement.dart';
import 'features/hr_task/models/hr_task_summary.dart';
import 'features/operations_workbench/models/operations_workbench.dart';
import 'features/procurement_iqc_rejection/models/procurement_iqc_rejection.dart';
import 'features/production/models/analysis_linked_sales_order.dart';
import 'features/production/models/production_draw_request.dart';
import 'features/production/models/production_execution_workbench.dart';
import 'features/production/models/reportable_plan_line.dart';
import 'features/production/models/workshop_material_report_models.dart';
import 'features/production/repositories/production_repository.dart';
import 'features/quality/models/production_fqc_inspection.dart';
import 'features/quality/models/quality_inspection_record.dart';
import 'features/sales/models/sales_doc.dart';
import 'features/sales/models/sales_order_progress.dart';
import 'features/stock/models/stock_query.dart';
import 'features/stock/repositories/stock_query_repository.dart';
import 'features/subcontract/models/subcontract_order_progress.dart';
import 'features/warehouse/materialbin/models/workshop_material_models.dart';
import 'features/warehouse/models/production_finished_inbound_task.dart';
import 'features/warehouse/models/subcontract_outbound.dart';
import 'features/warehouse/models/warehouse_document_history.dart';
import 'features/warehouse/models/warehouse_draw_task.dart';
import 'features/warehouse/models/warehouse_quality_result.dart';
import 'features/warehouse/repositories/procurement_inspection_repository.dart';
import 'features/warehouse/widgets/warehouse_stock_outbound_detail_table.dart';
import 'shared/measurement/weight_params.dart';
import 'shared/formatters/exact_decimal.dart';
import 'shared/platform_tables/platform_table_models.dart';
import 'shared/models/procurement_inbound.dart';
import 'shared/models/subcontract_short_delivery.dart';
import 'shared/stock_ledger/stock_ledger_models.dart';

/// Additional typed display sources. Keys match the actual table columns; values
/// come from authorized models, never formatted text or invented record IDs.
Map<String, String?>? additionalPlatformDisplayFacts(Object? row) {
  if (row is ProcurementIqcRejectionCase) {
    return {
      'failedQty': row.failedQty,
      'amount': row.priceMasked ? null : row.failedAmountLocal,
    };
  }
  if (row is GoodsBomLearningComponent) {
    return {
      'designQty': _raw(row.designQty),
      'actualQty': _raw(row.actual.qty),
      'perProducedQty': _raw(row.actual.perProducedQty),
      'netQty': _raw(row.actual.netQty),
      'exposureOutputQty': _raw(row.actual.outputQty),
      'defectQty': _raw(row.actual.defectQty),
      'defectRate': _raw(row.actual.defectRate),
      'sampleCount': _raw(row.actual.sampleCount),
    };
  }
  if (row is OperationsWorkbenchTask) {
    return {
      'requiredQty': _raw(
        row.isDocumentGrouped || row.isMaterialDiscovery
            ? null
            : row.requiredQty,
      ),
      'allocatedQty': _raw(
        row.isDocumentGrouped || row.isMaterialDiscovery
            ? null
            : row.allocatedQty,
      ),
      'fulfilledQty': _raw(
        row.isDocumentGrouped || row.isMaterialDiscovery
            ? null
            : row.fulfilledQty,
      ),
      'openQty': _raw(
        row.isDocumentGrouped || row.isMaterialDiscovery ? null : row.openQty,
      ),
    };
  }
  if (row is AnalysisLinkedSalesOrderLine) {
    return {
      'qty': _raw(row.qty),
      'shippedQty': _raw(row.shippedQty),
      'outstandingQty': _raw(row.outstandingQty),
      'reservedQty': _raw(row.reservedQty),
      'plannedQty': _raw(row.plannedQty),
      'producedQty': _raw(row.producedQty),
      'unplannedQty': _raw(row.unplannedQty),
    };
  }
  if (row is SchedulePendingRow) {
    return {
      'qty': _raw(row.qty),
      'needQty': _raw(row.needQty),
      'plannedQty': _raw(row.plannedQty),
      'analysisCoveredQty': _raw(row.analysisCoveredQty),
    };
  }
  if (row is ProductionDrawRequestSummary) {
    return {'qty': _raw(row.qty)};
  }
  if (row is ProductionExecutionWorkbenchSegment) {
    return {'qty': _raw(row.plannedQty)};
  }
  if (row is ScheduleBomComponent) {
    return {
      'perQty': _raw(row.perQty),
      'needQty': _raw(row.periodic ? null : row.needQty),
      'onhand': _raw(row.onhand),
    };
  }
  if (row is ReportablePlanLine) {
    return {
      'remaining': _raw(
        row.isFqcRecovery ? row.fqcRecoveryAvailableQty : row.remainingPlanQty,
      ),
      'maxReport': _raw(row.maxReportQty),
    };
  }
  if (row is ProductionWorkshopTaskMaterial) {
    return {
      'requiredQty': _raw(row.requiredQty),
      'warehouseAvailableQty': _raw(row.warehouseAvailableQty),
      'directReceivedQty': _raw(row.directReceivedQty),
      'issuedQty': _raw(row.issuedQty),
      'shortageQty': _raw(row.shortageQty),
    };
  }
  if (row is ProductionFqcInspection) {
    return {
      'reportedQty': _raw(row.reportedQty),
      'passedQty': _raw(row.passedQty),
      'failedQty': _raw(row.failedQty),
      'remainingQty': _raw(row.remainingQty),
      'authorizedInboundQty': _raw(row.authorizedInboundQty),
      'quantity': _raw(row.reportedQty),
    };
  }
  if (row is QualityInspectionRecord) {
    return {'passQty': _raw(row.passQty), 'failQty': _raw(row.failQty)};
  }
  if (row is ProcurementInspectionItem) {
    return {
      'receivedBaseQty': _raw(row.receivedBaseQty),
      'remainingBaseQty': _raw(row.remainingBaseQty),
    };
  }
  if (row is SalesOrderProgressRow) {
    return {
      'orderQty': _raw(row.orderQty),
      'producedQty': _raw(row.producedQty),
      'shippedQty': _raw(row.shippedQty),
      'reservedQty': _raw(row.reservedQty),
    };
  }
  if (row is OrderPlanProgressLine) {
    return {
      'qty': _raw(row.qty),
      'planned': _raw(row.plannedQty),
      'produced': _raw(row.producedQty),
      'shipped': _raw(row.shippedQty),
      'available': _raw(row.shippableQty),
      'pending': _raw(row.pendingShipmentQty),
    };
  }
  if (row is SubcontractShortDeliveryCase) {
    return {
      'orderedQty': _raw(row.orderedQty),
      'allowedLossPct': _raw(row.allowedLossPct),
      'floorQty': _raw(row.floorQty),
      'deliveredQty': _raw(row.deliveredQty),
      'shortfallQty': _raw(row.shortfallQty),
      'shortfallPct': _raw(row.shortfallPct),
      'arrivalCount': _raw(row.arrivalCount),
      'lossQty': _raw(row.lossQty),
      'lossPct': _raw(row.lossPct),
    };
  }
  if (row is SubcontractSupplierLedgerLine) {
    return {
      'atSupplierQty': _raw(row.atSupplierQty),
      'consumedQty': _raw(row.consumedQty),
      'returnedQty': _raw(row.returnedQty),
      'wastedQty': _raw(row.wastedQty),
      'supplierEnding': _raw(row.supplierEnding),
    };
  }
  if (row is WmPositionRow) {
    return {
      'estimatedRemainingQty': _raw(row.estimatedRemainingQty),
      'bookQty': _raw(row.bookQty),
      'periodInQty': _raw(row.periodInQty),
      'periodReturnQty': _raw(row.periodReturnQty),
      'periodOtherQty': _raw(row.periodOtherQty),
      'estimatedUsedQty': _raw(row.estimatedUsedQty),
      'warehouseAvailableQty': _raw(row.warehouseAvailableQty),
    };
  }
  if (row is WmRequisition) {
    return {'totalQty': _raw(row.totalQty), 'qty': _raw(row.totalQty)};
  }
  if (row is ProductionFinishedInboundTask) {
    return {
      'pendingQty': _raw(row.pendingQty),
      'lineCount': _raw(row.lineCount),
    };
  }
  if (row is WarehouseDrawTask) {
    return {
      'requiredQty': _raw(
        row.isBatchMerged ||
                (!row.isMaterialDiscovery && !row.isDocumentGrouped)
            ? row.requiredQty
            : null,
      ),
      'fulfilledQty': _raw(
        row.isBatchMerged ||
                (!row.isMaterialDiscovery && !row.isDocumentGrouped)
            ? row.fulfilledQty
            : null,
      ),
      'openQty': _raw(_warehouseDrawOpenQty(row)),
    };
  }
  if (row is ProcurementArrivalException) {
    return {
      'declaredQty': _raw(row.declaredQty),
      'approvedRemainingQty': _raw(row.approvedRemainingQty),
      'acceptedQty': _raw(row.acceptedQty),
      'unacceptedQty': _raw(row.unacceptedQty),
    };
  }
  if (row is BalanceRow) {
    return {'qty': _raw(row.qty), 'weight': _raw(row.weight)};
  }
  if (row is StockLedgerRow) {
    return {
      'inQty': _raw(
        row.isWeightAdjustment || !row.isInbound ? null : row.qtySigned?.abs(),
      ),
      'outQty': _raw(
        row.isWeightAdjustment || row.isInbound ? null : row.qtySigned?.abs(),
      ),
      'balanceQty': _raw(row.balanceQtyAfter),
      'inWeight': _raw(_ledgerWeightOnSide(row, inbound: true)),
      'outWeight': _raw(_ledgerWeightOnSide(row, inbound: false)),
      'balanceWeight': _raw(row.balanceWeightKgAfter),
    };
  }
  if (row is WarehouseDocumentPhysicalItem) {
    return {
      'quantity': _raw(row.qty),
      'weight': row.weight,
      'boxQuantity': _raw(row.boxQty),
      'returnedQuantity': _raw(row.returnedQty),
      'wastedQuantity': _raw(row.wastedQty),
      'atSupplierQuantity': _raw(row.atSupplierQty),
      'consumedQuantity': _raw(row.consumedQty),
      'supplierEndingQuantity': _raw(row.supplierEndingQty),
      'endingQuantity': _raw(row.endingQty),
      'standardQuantity': _raw(row.standardQty),
      'wasteRate': _raw(row.wasteRate),
      'iqcPassedBaseQuantity': _raw(row.passedBaseQty),
      'iqcStockedBaseQuantity': _raw(row.stockedBaseQty),
      'iqcPendingStockInBaseQuantity': _raw(row.pendingStockInBaseQty),
      'iqcFailedBaseQuantity': _raw(row.failedBaseQty),
    };
  }
  if (row is WarehouseStockOutboundRow) {
    return {'qty': _raw(row.item.qty), 'weight': _raw(row.item.weight)};
  }
  if (row is WeightObservation) {
    return {'qty': _raw(row.qtyBase), 'weight': _raw(row.weightKg)};
  }
  if (row is GoodsWeightEstimateRow) {
    return {'nRef': _raw(row.nRef)};
  }
  if (row is ShelfLabelRow) {
    return {'qty': _raw(row.qty)};
  }
  if (row is WarehouseQualityResultTask) {
    return {
      'pendingSliceCount': _raw(row.pendingSliceCount),
      'pendingReturnCount': _raw(row.pendingReturnCount),
    };
  }
  if (row is WarehouseDocumentHistorySummary) {
    return {'itemCount': _raw(row.itemCount)};
  }
  if (row is InboundExpectation) {
    return {'itemCount': _raw(row.items.length)};
  }
  if (row is OutboundTask) {
    return {'lineCount': _raw(row.lineCount)};
  }
  if (row is HrTaskItem) {
    return {'days': _raw(row.days)};
  }
  if (row is WmBinUsageRow) {
    return {
      'theory': _raw(
        row.costBasis == 'SHARED' ? row.allocationBasisQty : row.theoryQty,
      ),
      'wasteRate': _percent(row.wasteRate),
    };
  }
  if (row is WmProductUsageRow) {
    return {
      'unitWeight': _raw(row.unitWeightGrams),
      'actualPerUnit': _raw(
        row.exclusivePeriod ? row.actualPerUnitGrams : null,
      ),
      'amount': row.materialAmountText,
      'valueAtClose': row.valueAtCloseText,
      'unitCost': row.unitMaterialCostText,
    };
  }
  if (row is WmMissingWeightRow) {
    return {'output': _raw(row.outputQty)};
  }
  if (row is WmLedgerRow) {
    return {'qty': _raw(row.signedQty)};
  }
  if (row is ArApLedgerItem) {
    return {
      'exchangeRate': _raw(row.exchangeRateText),
      'amountOriginal': _raw(row.amountOriginalText),
      'amountReceivedOriginal': _raw(row.amountReceivedOriginalText),
      'amountWriteOffOriginal': _raw(row.amountWriteOffOriginalText),
      'prepaymentAppliedOriginal': _raw(row.prepaymentAppliedOriginal),
      'amountBalanceOriginal': _raw(row.amountBalanceOriginalText),
      'amountBalance': _raw(row.amountBalanceText),
    };
  }
  if (row is FinancePayableItem) {
    return {
      'grossOriginal': _raw(row.grossOriginal),
      'grossLocal': _raw(row.grossLocal),
      'paidOriginal': _raw(row.paidOriginal),
      'paidLocal': _raw(row.paidLocal),
      'offsetOriginal': _raw(row.offsetOriginal),
      'offsetLocal': _raw(row.offsetLocal),
      'outstandingOriginal': _raw(row.outstandingOriginal),
      'outstandingLocal': _raw(row.outstandingLocal),
      'overdueDays': _raw(row.overdueDays),
    };
  }
  if (row is ReconciliationItem) {
    return {'inAmount': row.inAmountText, 'outAmount': row.outAmountText};
  }
  if (row is FinanceAssetScheduleLine) {
    return {
      'openingBalance': _raw(row.openingBalance),
      'amount': _raw(row.amount),
      'accumulatedAmount': _raw(row.accumulatedAmount),
      'closingBalance': _raw(row.closingBalance),
    };
  }
  if (row is AssetPostingLine) {
    return {'amount': _raw(row.amount)};
  }
  if (row is SupplierSettlementSummary) {
    return {
      'openingBalanceOriginal': _raw(row.openingBalanceOriginal),
      'periodPostedOriginal': _raw(row.periodPostedOriginal),
      'periodPaidOriginal': _raw(row.periodPaidOriginal),
      'periodOffsetOriginal': _raw(row.periodOffsetOriginal),
      'closingBalanceOriginal': _raw(row.closingBalanceOriginal),
      'lineCount': _raw(row.lineCount),
    };
  }
  if (row is SupplierSettlementLine) {
    return {
      'openingBalanceOriginal': _raw(row.openingBalanceOriginal),
      'periodPostedOriginal': _raw(row.periodPostedOriginal),
      'periodPaidOriginal': _raw(row.periodPaidOriginal),
      'periodOffsetOriginal': _raw(row.periodOffsetOriginal),
      'closingBalanceOriginal': _raw(row.closingBalanceOriginal),
    };
  }
  if (row is SubcontractLossClaimLine) {
    return {
      'actualLossQty': _raw(row.actualLossQty),
      'allowedLossQty': _raw(row.allowedLossQty),
      'excessLossQty': _raw(row.excessLossQty),
      'unitBookValueLocal': _raw(row.unitBookValueLocal),
      'lossBookValueLocal': _raw(row.lossBookValueLocal),
    };
  }
  if (row is SubcontractLossClaimSummary) {
    return {
      'actualLossQty': _raw(row.actualLossQty),
      'allowedLossQty': _raw(row.allowedLossQty),
      'excessLossQty': _raw(row.excessLossQty),
      'lossBookValueLocal': _raw(
        row.priceMasked ? null : row.lossBookValueLocal,
      ),
      'claimAmountLocal': _raw(row.priceMasked ? null : row.claimAmountLocal),
    };
  }
  if (row is FinanceProcurementApprovalTask) {
    return {
      'totalOriginal': _raw(row.totalOriginal),
      'amount': _raw(row.amount),
      'attempt': _raw(row.attempt),
    };
  }
  if (row is SalesQuoteFinanceListItem) {
    return {
      'lineCount': _raw(row.lineCount),
      'totalOriginal': _raw(row.totalOriginal),
    };
  }
  if (row is SalesOrderFinancePendingItem) {
    return {
      'totalOriginal': _raw(row.totalOriginal),
      'itemCount': _raw(row.itemCount),
      'clientBalance': _raw(row.clientBalance?.netOriginal),
    };
  }
  return null;
}

String? _raw(Object? value) => value?.toString();

String? _percent(num? ratio) {
  final raw = platformExactFact(ratio);
  return raw == null ? null : financeExactMultiplyTexts([raw, '100']);
}

num? _warehouseDrawOpenQty(WarehouseDrawTask row) {
  if (row.isBatchMerged) return row.openQty;
  if (row.isMaterialDiscovery &&
      (!row.materialsDefined || row.openLineCount > 1 || row.openQty <= 0)) {
    return null;
  }
  return row.isDocumentGrouped ? null : row.openQty;
}

double? _ledgerWeightOnSide(StockLedgerRow row, {required bool inbound}) {
  final weight = row.weightKgSigned;
  final shown = row.isWeightAdjustment
      ? weight != null && weight != 0 && (weight > 0) == inbound
      : row.isInbound == inbound;
  return shown ? weight?.abs() : null;
}

/// Monetary views keep the same narrow authorization as their source query.
String? additionalPlatformDisplayScope(Type type) {
  if (type == ProcurementIqcRejectionCase) {
    return 'view_procurement_iqc_rejection';
  }
  if (type == ReconciliationItem) return 'view_account_statement';
  if (type == ArApLedgerItem || type == FinancePayableItem) {
    return 'view_ar_ap_ledger';
  }
  if (type == FinanceAssetScheduleLine || type == AssetPostingLine) {
    return 'view_finance_asset';
  }
  if (type == SupplierSettlementSummary || type == SupplierSettlementLine) {
    return 'view_supplier_settlement';
  }
  if (type == SubcontractLossClaimLine || type == SubcontractLossClaimSummary) {
    return 'view_subcontract_loss_claim';
  }
  if (type == FinanceProcurementApprovalTask) {
    return 'view_finance_order_approval';
  }
  if (type == SalesQuoteFinanceListItem) return 'view_sales_quote_finance';
  if (type == SalesOrderFinancePendingItem) return 'view_sales_order_finance';
  return null;
}
