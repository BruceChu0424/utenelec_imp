import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_inline_notice.dart';
import 'form_draft_category.dart';
import 'task_form_drafts.dart';

/// The server may finish a task while its response is lost. Keep a recovery
/// action in the task's workbench even after that row leaves the pending query.
/// It resumes the original checkpoint; it never creates another business row.
class TaskDraftRecoveryNotice extends ConsumerWidget {
  const TaskDraftRecoveryNotice({
    super.key,
    required this.scope,
    this.visibleDraftIds = const {},
  });

  final FormDraftCategoryScope scope;
  final Set<String> visibleDraftIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drafts = taskDraftsFor(
      ref.watch(formDraftCategoryProvider(scope)),
      matches: (draft) =>
          isTaskFormDraft(draft) &&
          (draft.hasUnknownSubmission || !visibleDraftIds.contains(draft.id)),
    );
    if (drafts.isEmpty) return const SizedBox.shrink();
    final unknownCount = drafts
        .where((draft) => draft.hasUnknownSubmission)
        .length;
    return UtenInlineNotice(
      key: const ValueKey('task-draft-recovery-notice'),
      level: unknownCount > 0
          ? UtenInlineNoticeLevel.warning
          : UtenInlineNoticeLevel.info,
      message: unknownCount > 0
          ? '$unknownCount 份任务提交结果待核对，原填写与请求已保留。'
          : '${drafts.length} 份任务填写已保留，可继续原填写或核对已变化的来源。',
      trailing: UtenButton(
        type: UtenButtonType.secondary,
        onPressed: () => resumeTaskFormDraft(
          context,
          ref,
          drafts,
          choose: drafts.any((draft) => !draft.hasUnknownSubmission),
        ),
        child: Text(unknownCount > 0 ? '核对原提交' : '继续原填写'),
      ),
    );
  }
}
