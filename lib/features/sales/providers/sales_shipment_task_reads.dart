import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../models/sales_doc.dart';
import '../repositories/sales_repository.dart';

/// The list and its bill-number facets share the same workflow predicate.
SalesDocFilter salesShipmentTaskFilter({
  required bool finance,
  int? financeAudit,
  bool financeRejected = false,
  String? warehouseWorkStatus,
  String? keyword,
  String? billNo,
}) => SalesDocFilter(
  keyword: keyword == null || keyword.trim().isEmpty ? null : keyword.trim(),
  status: finance && financeAudit != 0 ? null : kSalesStatusDraft,
  financeAudit: financeAudit,
  financeRejected: financeRejected ? true : null,
  warehouseWorkStatus: finance
      ? (financeAudit == 0 ? SalesWarehouseWorkStatus.pendingPick : null)
      : warehouseWorkStatus,
  billNo: billNo,
);

Future<void> prepareFinanceShipmentFirstPage(Ref ref) async {
  if (!ref.read(isSuperAdminProvider) &&
      !ref
          .read(currentPermissionsProvider)
          .contains(Perm.salesShipmentFinanceView)) {
    return;
  }
  await ref
      .read(salesRepositoryProvider(SalesDocType.shipment))
      .prepareList(
        filter: salesShipmentTaskFilter(finance: true, financeAudit: 0),
      );
}
