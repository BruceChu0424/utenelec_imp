import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/uten_tokens.dart';
import '../auth/permissions.dart';
import '../models/procurement_order_closure.dart';

/// Only known business routes are derived from the structured blocker. A server
/// error message or an arbitrary URL cannot become a navigation instruction.
String? procurementClosureBlockerRoute(ProcurementOrderClosureBlocker blocker) {
  if (!const {'PURCHASE', 'SUBCONTRACT'}.contains(blocker.orderType)) {
    return null;
  }
  final id = blocker.documentId?.trim();
  final hasId = id?.isNotEmpty == true;
  final prefix = blocker.orderType == 'PURCHASE' ? '/purchase' : '/subcontract';
  return switch (blocker.kind) {
    'QUALITY_INSPECTION' =>
      hasId
          ? RouteName.warehouseInspectionDetail(
              blocker.orderType,
              Uri.encodeComponent(id!),
            )
          : RouteName.qualityTaskCenter,
    'WAREHOUSE_IQC_RETURN' =>
      hasId
          ? RouteName.warehouseQualityResultDetail(blocker.orderType, id!)
          : RouteName.warehouseQualityResults,
    'WAREHOUSE_RECEIPT' =>
      hasId
          ? '$prefix/receipts/${Uri.encodeComponent(id!)}'
          : '$prefix/receipts',
    'WAREHOUSE_RETURN' =>
      hasId ? '$prefix/returns/${Uri.encodeComponent(id!)}' : '$prefix/returns',
    'SUBCONTRACT_DRAW'
        when blocker.orderType == 'SUBCONTRACT' && blocker.orderId.isNotEmpty =>
      RouteName.operationsSubcontractDrawSegment(orderId: blocker.orderId),
    'ARRIVAL_EXCEPTION' =>
      hasId
          ? RoutePath.procurementArrivalException(Uri.encodeComponent(id!))
          : Uri(
              path: RouteName.procurementArrivalExceptions,
              queryParameters: {'orderType': blocker.orderType},
            ).toString(),
    'FINANCE' =>
      hasId
          ? '/finance/procurement-approvals/${Uri.encodeComponent(id!)}'
          : '/finance/procurement-approvals',
    _ => null,
  };
}

String? procurementClosureBlockerPermission(
  ProcurementOrderClosureBlocker blocker,
) => switch (blocker.kind) {
  'QUALITY_INSPECTION' => Perm.procurementInspectionView,
  'WAREHOUSE_IQC_RETURN' => Perm.warehouseIqcReturnView,
  'WAREHOUSE_RECEIPT' =>
    blocker.orderType == 'PURCHASE'
        ? Perm.purchaseReceiptView
        : Perm.subcontractReceiptView,
  'WAREHOUSE_RETURN' =>
    blocker.orderType == 'PURCHASE'
        ? Perm.purchaseReturnView
        : Perm.subcontractReturnView,
  'SUBCONTRACT_DRAW' => Perm.subcontractOrderView,
  'ARRIVAL_EXCEPTION' => Perm.supplierReturnTaskView,
  'FINANCE' => Perm.financeOrderApprovalView,
  _ => null,
};

class ProcurementOrderClosureBlockerAction extends ConsumerWidget {
  const ProcurementOrderClosureBlockerAction({
    super.key,
    required this.blocker,
    required this.onOpen,
    this.busy = false,
  });

  final ProcurementOrderClosureBlocker blocker;
  final Future<void> Function(String route) onOpen;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final permission = procurementClosureBlockerPermission(blocker);
    final route = procurementClosureBlockerRoute(blocker);
    final allowed =
        permission != null &&
        route != null &&
        (ref.watch(isSuperAdminProvider) ||
            ref.watch(currentPermissionsProvider).contains(permission));
    final contact = switch (blocker.kind) {
      'QUALITY_INSPECTION' => l10n.orderClosureContactQuality,
      'WAREHOUSE_IQC_RETURN' ||
      'WAREHOUSE_RECEIPT' ||
      'WAREHOUSE_RETURN' ||
      'ARRIVAL_EXCEPTION' => l10n.orderClosureContactWarehouse,
      'SUBCONTRACT_DRAW' => l10n.orderClosureContactSubcontract,
      'FINANCE' => l10n.orderClosureContactFinance,
      _ => l10n.orderClosureUnavailable,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (blocker.kind == 'QUALITY_INSPECTION')
          Text(l10n.orderClosureQualityPreserved),
        Text(contact),
        if (allowed) ...[
          const SizedBox(height: UtenSpacing.s8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: UtenButton(
              key: const Key('procurement-order-closure-blocker-open'),
              type: UtenButtonType.secondary,
              icon: Icons.open_in_new_rounded,
              isLoading: busy,
              onPressed: busy ? null : () => onOpen(route),
              child: Text(l10n.orderClosureHandleBlocker),
            ),
          ),
        ],
      ],
    );
  }
}
