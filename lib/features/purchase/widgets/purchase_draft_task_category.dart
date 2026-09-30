import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/draft_workspace_table.dart';
import '../../../shared/drafts/form_draft_category.dart';
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';

/// 采购草稿共用一张表，单据类别在首列筛选，不再嵌套列表的状态工具条。
class PurchaseDraftTaskCategory extends ConsumerWidget {
  const PurchaseDraftTaskCategory({
    super.key,
    this.search = '',
    this.externalHeader,
  });

  final String search;
  final Widget? externalHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    return DraftWorkspaceTable(
      tableKey: 'purchase.task-center.drafts',
      kinds: [
        for (final type in [
          PurchaseDocType.order,
          PurchaseDocType.receipt,
          PurchaseDocType.returnDoc,
        ])
          if (superAdmin ||
              permissions.contains(PurchaseDocConfig.by(type).listPerm))
            PurchaseDocConfig.by(type).draftKind!,
      ],
      localScope: const FormDraftCategoryScope(module: BadgeModule.purchase),
      search: search,
      showSearch: externalHeader == null,
      externalHeader: externalHeader,
    );
  }
}
