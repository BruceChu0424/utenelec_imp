import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_context_menu.dart';
import '../../features/finance/config/finance_doc_config.dart';
import '../../features/finance/models/finance_doc.dart';
import '../../features/purchase/config/purchase_doc_config.dart';
import '../../features/purchase/models/purchase_doc.dart';
import '../../features/sales/config/sales_doc_config.dart';
import '../../features/sales/models/sales_doc.dart';
import '../../features/subcontract/config/subcontract_doc_config.dart';
import '../../features/subcontract/models/subcontract_doc.dart';
import '../auth/permissions.dart';
import '../providers/authenticated_scope_provider.dart';
import '../providers/draft_counts_provider.dart';

class DraftWorkspaceCreateAction {
  const DraftWorkspaceCreateAction({
    required this.label,
    required this.location,
    required this.permissions,
  });

  final String label;
  final String location;
  final List<String> permissions;
}

/// Keep each existing list's creation contract. Source-bound subcontract
/// entries retain their source registration routes and explicit action labels.
List<DraftWorkspaceCreateAction> draftWorkspaceCreateActions(
  Iterable<DraftDocKind> kinds,
) {
  final included = kinds.toSet();
  return [
    for (final type in PurchaseDocType.values)
      if (included.contains(PurchaseDocConfig.by(type).draftKind) &&
          PurchaseDocConfig.by(type).allowDirectCreate &&
          PurchaseDocConfig.by(type).createPerm != null)
        DraftWorkspaceCreateAction(
          label: '新建${PurchaseDocConfig.by(type).label}',
          location: '/purchase/${type.pathSegment}/new',
          permissions: [
            PurchaseDocConfig.by(type).listPerm,
            PurchaseDocConfig.by(type).createPerm!,
          ],
        ),
    for (final type in [
      SubcontractDocType.order,
      SubcontractDocType.returnDoc,
      SubcontractDocType.materialReturn,
      SubcontractDocType.waste,
    ])
      if (included.contains(SubcontractDocConfig.by(type).draftKind) &&
          SubcontractDocConfig.by(type).createPerm != null)
        DraftWorkspaceCreateAction(
          label: switch (type) {
            SubcontractDocType.order => '创建新委外单',
            SubcontractDocType.returnDoc => '从回厂来源登记退回',
            SubcontractDocType.materialReturn => '从在外结存登记余料',
            _ => '从在外结存登记损耗',
          },
          location: '/subcontract/${type.pathSegment}/new',
          permissions: [
            SubcontractDocConfig.by(type).listPerm,
            SubcontractDocConfig.by(type).createPerm!,
          ],
        ),
    for (final type in FinanceDocType.values)
      if (included.contains(FinanceDocConfig.by(type).draftKind) &&
          FinanceDocConfig.by(type).createPerm != null)
        DraftWorkspaceCreateAction(
          label: '新建${FinanceDocConfig.by(type).label}',
          location: '/finance/${type.pathSegment}/new',
          permissions: [
            FinanceDocConfig.by(type).listPerm,
            FinanceDocConfig.by(type).createPerm!,
          ],
        ),
    for (final type in SalesDocType.values)
      if (type != SalesDocType.otherShipment &&
          included.contains(
            type == SalesDocType.customerShipment
                ? DraftDocKind.salesShipment
                : SalesDocConfig.by(type).draftKind,
          ) &&
          SalesDocConfig.by(type).createPerm != null)
        DraftWorkspaceCreateAction(
          label: '新建${SalesDocConfig.by(type).label}',
          location: '/sales/${type.pathSegment}/new',
          permissions: [
            SalesDocConfig.by(type).listPerm,
            SalesDocConfig.by(type).createPerm!,
          ],
        ),
  ];
}

/// One toolbar action replaces the per-category create buttons lost when the
/// draft tables merge. The menu changes document creation, never row filtering.
class DraftWorkspaceCreateButton extends ConsumerWidget {
  const DraftWorkspaceCreateButton({super.key, required this.kinds});

  final List<DraftDocKind> kinds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final granted = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    final identity = ref.watch(authenticatedScopeProvider);
    if (identity?.readOnly == true) return const SizedBox.shrink();
    final actions = draftWorkspaceCreateActions(kinds)
        .where(
          (action) => superAdmin || action.permissions.every(granted.contains),
        )
        .toList();
    if (actions.isEmpty) return const SizedBox.shrink();

    Future<void> open(DraftWorkspaceCreateAction action) async {
      if (!context.mounted ||
          ref.read(authenticatedScopeProvider) != identity ||
          ref.read(authenticatedScopeProvider)?.readOnly == true ||
          (!ref.read(isSuperAdminProvider) &&
              !action.permissions.every(
                ref.read(currentPermissionsProvider).contains,
              ))) {
        return;
      }
      await context.push(action.location);
    }

    return Builder(
      builder: (buttonContext) => UtenButton(
        key: const Key('draft-workspace-create'),
        icon: Icons.add_rounded,
        type: UtenButtonType.tonal,
        onPressed: () {
          if (actions.length == 1) {
            open(actions.single);
            return;
          }
          final box = buttonContext.findRenderObject() as RenderBox;
          showUtenContextMenu(
            buttonContext,
            globalPosition: box.localToGlobal(Offset(0, box.size.height)),
            entries: [
              for (final action in actions)
                UtenMenuItem(label: action.label, onTap: () => open(action)),
            ],
          );
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('新建'),
            if (actions.length > 1)
              const Icon(Icons.expand_more_rounded, size: 18),
          ],
        ),
      ),
    );
  }
}
