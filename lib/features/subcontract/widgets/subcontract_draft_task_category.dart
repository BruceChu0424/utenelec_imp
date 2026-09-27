import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_category.dart';
import '../../../shared/providers/draft_counts_provider.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart';
import '../pages/subcontract_page_factory.dart';

class SubcontractDraftTaskCategory extends ConsumerStatefulWidget {
  const SubcontractDraftTaskCategory({super.key});
  @override
  ConsumerState<SubcontractDraftTaskCategory> createState() =>
      _SubcontractDraftTaskCategoryState();
}

class _SubcontractDraftTaskCategoryState
    extends ConsumerState<SubcontractDraftTaskCategory> {
  SubcontractDocType _type = SubcontractDocType.order;
  bool _showOtherDrafts = false;
  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(currentPermissionsProvider);
    final types =
        [
              SubcontractDocType.order,
              SubcontractDocType.returnDoc,
              SubcontractDocType.materialReturn,
              SubcontractDocType.waste,
            ]
            .where(
              (type) =>
                  permissions.contains(SubcontractDocConfig.by(type).listPerm),
            )
            .toList();
    const otherScope = FormDraftCategoryScope(
      module: BadgeModule.subcontract,
      excludeKinds: {
        'subcontractOrder',
        'subcontractReturn',
        'subcontractMaterialReturn',
        'subcontractWaste',
      },
    );
    final otherCount = ref.watch(
      formDraftCategoryVisibleCountProvider(otherScope),
    );
    final hasOther = otherCount > 0 || _showOtherDrafts;
    if (types.isEmpty && !hasOther) {
      return const Center(child: Text('暂无可查看的委外草稿'));
    }
    final selected = types.contains(_type) ? _type : types.firstOrNull;
    final showingOther = hasOther && (_showOtherDrafts || selected == null);
    final counts = ref.watch(draftCountsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenFilterToolbar<String>(
          segmentsKey: const Key('subcontract-draft-document-types'),
          segments: [
            for (final type in types)
              UtenFilterSegment(
                value: type.name,
                label: SubcontractDocConfig.by(type).label,
                count: counts.of(SubcontractDocConfig.by(type).draftKind!),
                countForm: UtenSegmentCountForm.actionable,
              ),
            if (hasOther)
              UtenFilterSegment(
                value: 'otherDrafts',
                label: '其他草稿',
                count: otherCount,
                countForm: UtenSegmentCountForm.actionable,
              ),
          ],
          selected: {showingOther ? 'otherDrafts' : selected!.name},
          onSelectionChanged: (type) => setState(() {
            _showOtherDrafts = type == 'otherDrafts';
            if (!_showOtherDrafts) {
              _type = SubcontractDocType.values.byName(type);
            }
          }),
        ),
        Expanded(
          child: showingOther
              ? const FormDraftCategoryList(scope: otherScope)
              : KeyedSubtree(
                  key: ValueKey(selected),
                  child: SubcontractPageFactory.list(
                    selected!,
                    initialStatus: kDraftStatusQuery,
                    embedded: true,
                  ),
                ),
        ),
      ],
    );
  }
}
