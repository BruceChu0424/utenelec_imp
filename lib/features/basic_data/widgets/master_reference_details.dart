import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_dialog.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../models/master_batch.dart';
import 'master_edit_owner.dart';

/// Only stable server identities are used for links; labels are never parsed.
String? masterReferenceLocation(
  MasterReference reference, {
  required String partyId,
}) {
  final id = reference.id;
  return switch (reference.kind) {
    'GOODS' => RoutePath.basicinfoGoodsDetail(id),
    'SALES_QUOTE' => RoutePath.salesDocDetail('quotes', id),
    'SALES_ORDER' => RoutePath.salesDocDetail('orders', id),
    'SHIPMENT' => RoutePath.salesDocDetail('shipments', id),
    'SALES_OTHER_SHIPMENT' => RoutePath.salesDocDetail('other-shipments', id),
    'SALES_RETURN' => RoutePath.salesDocDetail('returns', id),
    'PURCHASE_ORDER' => RoutePath.purchaseDocDetail('orders', id),
    'PURCHASE_RECEIPT' => RoutePath.purchaseDocDetail('receipts', id),
    'PURCHASE_RETURN' => RoutePath.purchaseDocDetail('returns', id),
    'SUBCONTRACT_INQUIRY' => RoutePath.subcontractDocDetail('inquiries', id),
    'SUBCONTRACT_APPLICATION' => RoutePath.subcontractDocDetail(
      'applications',
      id,
    ),
    'SUBCONTRACT_ORDER' => RoutePath.subcontractDocDetail('orders', id),
    'SUBCONTRACT_RECEIPT' => RoutePath.subcontractDocDetail('receipts', id),
    'SUBCONTRACT_RETURN' => RoutePath.subcontractDocDetail('returns', id),
    'SUBCONTRACT_WASTE' => RoutePath.subcontractDocDetail('wastes', id),
    'SUBCONTRACT_MATERIAL_ISSUE' => RoutePath.subcontractDocDetail(
      'material-issues',
      id,
    ),
    'SUBCONTRACT_MATERIAL_RETURN' => RoutePath.subcontractDocDetail(
      'material-returns',
      id,
    ),
    'FINANCE_RECEIPT' => RoutePath.financeDocDetail('receipts', id),
    'FINANCE_PAYMENT' => RoutePath.financeDocDetail('payments', id),
    'RECEIVABLE' || 'PAYABLE' => Uri(
      path: RouteName.financeArAp,
      queryParameters: {
        'partyId': partyId,
        'direction': reference.kind == 'RECEIVABLE' ? 'AR' : 'AP',
      },
    ).toString(),
    _ => null,
  };
}

Future<void> showMasterReferenceDetails(
  BuildContext context,
  WidgetRef ref, {
  required String entityPath,
  required List<MasterBatchItemResult> items,
}) async {
  final owner = MasterEditOwner(
    context,
    ref,
    permissions: {
      entityPath.endsWith('/clients') ? Perm.clientView : Perm.supplierView,
    },
    requireWrite: false,
  );
  if (!owner.isCurrent) {
    owner.dispose();
    return;
  }
  try {
    final permissions = ref.read(currentPermissionsProvider);
    final superAdmin = ref.read(isSuperAdminProvider);
    final rows = <({MasterBatchItemResult item, MasterReference? reference})>[
      for (final item in items) ...[
        (item: item, reference: null),
        for (final reference in item.references)
          (item: item, reference: reference),
      ],
    ];
    final location = await showDialog<String>(
      context: context,
      builder: (dialogContext) => owner.ownDialog(
        dialogContext,
        UtenAlertDialog(
          title: const Text('关联业务'),
          showCloseButton: true,
          scrollable: false,
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.sizeOf(dialogContext).height * 0.55,
            child: ListView.builder(
              itemCount: rows.length,
              itemBuilder: (_, index) {
                final row = rows[index];
                final reference = row.reference;
                if (reference == null) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: UtenSpacing.s8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row.item.label ?? '该资料',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: UtenSpacing.s8),
                        Text(row.item.reason ?? '仍有关联业务，历史记录继续保留。'),
                      ],
                    ),
                  );
                }
                final target = masterReferenceLocation(
                  reference,
                  partyId: row.item.id,
                );
                final canOpen =
                    target != null &&
                    businessLocationAllowedFor(permissions, superAdmin, target);
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(reference.label),
                  subtitle: !canOpen ? const Text('关联记录继续保留') : null,
                  trailing: canOpen ? const Icon(Icons.open_in_new) : null,
                  onTap: canOpen
                      ? () {
                          if (owner.isCurrent) {
                            Navigator.of(dialogContext).pop(target);
                          }
                        }
                      : null,
                );
              },
            ),
          ),
        ),
      ),
    );
    if (location != null && owner.isCurrent && context.mounted) {
      goFrom(context, location);
    }
  } finally {
    owner.dispose();
  }
}
