import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_category.dart';
import '../../../shared/providers/draft_counts_provider.dart';
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';
import '../pages/purchase_doc_list_page.dart';

class PurchaseDraftTaskCategory extends ConsumerStatefulWidget {
  const PurchaseDraftTaskCategory({super.key});
  @override
  ConsumerState<PurchaseDraftTaskCategory> createState() =>
      _PurchaseDraftTaskCategoryState();
}

class _PurchaseDraftTaskCategoryState
    extends ConsumerState<PurchaseDraftTaskCategory> {
  PurchaseDocType _type = PurchaseDocType.order;
  bool _showMasterDrafts = false;
  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(currentPermissionsProvider);
    final types =
        [
              PurchaseDocType.order,
              PurchaseDocType.receipt,
              PurchaseDocType.returnDoc,
            ]
            .where(
              (type) =>
                  permissions.contains(PurchaseDocConfig.by(type).listPerm),
            )
            .toList();
    const masterScope = FormDraftCategoryScope(
      module: BadgeModule.purchase,
      routePrefix: '/basicinfo/',
    );
    final masterCount = ref.watch(
      formDraftCategoryVisibleCountProvider(masterScope),
    );
    final hasMaster =
        masterCount > 0 || permissions.contains(Perm.supplierView);
    if (types.isEmpty && !hasMaster) {
      return const Center(child: Text('暂无可查看的采购草稿'));
    }
    final selected = types.contains(_type) ? _type : types.firstOrNull;
    final showingMaster = hasMaster && (_showMasterDrafts || selected == null);
    final counts = ref.watch(draftCountsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenFilterToolbar<String>(
          segmentsKey: const Key('purchase-draft-document-types'),
          segments: [
            for (final type in types)
              UtenFilterSegment(
                value: type.name,
                label: PurchaseDocConfig.by(type).label,
                count: counts.of(PurchaseDocConfig.by(type).draftKind!),
                countForm: UtenSegmentCountForm.actionable,
              ),
            if (hasMaster)
              UtenFilterSegment(
                value: 'masterDrafts',
                label: '资料草稿',
                count: masterCount,
                countForm: UtenSegmentCountForm.actionable,
              ),
          ],
          selected: {showingMaster ? 'masterDrafts' : selected!.name},
          onSelectionChanged: (type) => setState(() {
            _showMasterDrafts = type == 'masterDrafts';
            if (!_showMasterDrafts) _type = PurchaseDocType.values.byName(type);
          }),
        ),
        Expanded(
          child: showingMaster
              ? const FormDraftCategoryList(scope: masterScope)
              : PurchaseDocListPage(
                  key: ValueKey(selected),
                  docType: selected!,
                  initialStatus: kDraftStatusQuery,
                  embedded: true,
                ),
        ),
      ],
    );
  }
}
