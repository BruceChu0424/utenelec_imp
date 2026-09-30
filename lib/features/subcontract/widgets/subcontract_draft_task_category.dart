import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/draft_workspace_table.dart';
import '../../../shared/drafts/form_draft_category.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart';

/// 委外业务草稿和本机填写草稿共用一张可按类别筛选的表。
class SubcontractDraftTaskCategory extends ConsumerWidget {
  const SubcontractDraftTaskCategory({
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
      tableKey: 'subcontract.task-center.drafts',
      kinds: [
        for (final type in [
          SubcontractDocType.order,
          SubcontractDocType.returnDoc,
          SubcontractDocType.materialReturn,
          SubcontractDocType.waste,
        ])
          if (superAdmin ||
              permissions.contains(SubcontractDocConfig.by(type).listPerm))
            SubcontractDocConfig.by(type).draftKind!,
      ],
      localScope: const FormDraftCategoryScope(module: BadgeModule.subcontract),
      search: search,
      showSearch: externalHeader == null,
      externalHeader: externalHeader,
    );
  }
}
