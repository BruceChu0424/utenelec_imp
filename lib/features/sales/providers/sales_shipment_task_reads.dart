import '../models/sales_doc.dart';
import '../repositories/sales_repository.dart';

/// The list and its bill-number facets share the same workflow predicate.
SalesDocFilter salesShipmentTaskFilter({
  required bool finance,
  int? financeAudit,
  bool financeRejected = false,
  bool financeHistory = false,
  String? warehouseWorkStatus,
  String? keyword,
  String? billNo,
}) => SalesDocFilter(
  keyword: keyword == null || keyword.trim().isEmpty ? null : keyword.trim(),
  status: finance && financeAudit != 0 ? null : kSalesStatusDraft,
  financeAudit: financeHistory ? null : financeAudit,
  stage: financeHistory ? 'FINANCE_HISTORY' : null,
  financeRejected: financeRejected ? true : null,
  warehouseWorkStatus: finance
      ? (financeAudit == 0 ? SalesWarehouseWorkStatus.pendingPick : null)
      : warehouseWorkStatus,
  billNo: billNo,
);
