import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_notification_badge.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import '../../core/utils/china_datetime.dart';
import 'form_draft.dart';
import 'form_draft_store.dart';

/// 各任务中心共用的未完成填写草稿；只读取当前身份仍有权继续填写的记录。
class FormDraftsPanel extends ConsumerStatefulWidget {
  const FormDraftsPanel({super.key, this.module, this.routePrefix});

  final BadgeModule? module;

  /// 人事模块内「我的报销」等独立入口只展示自己的草稿。
  final String? routePrefix;

  @override
  ConsumerState<FormDraftsPanel> createState() => _FormDraftsPanelState();
}

class _FormDraftsPanelState extends ConsumerState<FormDraftsPanel> {
  bool _expanded = true;
  final Set<String> _deleting = {};

  Future<void> _delete(FormDraft draft) async {
    final store = ref.read(formDraftsProvider.notifier);
    final owner = store.ownerKey;
    if (draft.hasUnknownSubmission) {
      context.appWarning(formDraftUnknownSubmissionMessage);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除草稿？'),
        content: Text('删除后无法继续填写「${draft.title}」。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final latest = ref
        .read(formDraftsProvider)
        .where((item) => item.id == draft.id)
        .firstOrNull;
    if (store.ownerKey != owner ||
        latest == null ||
        latest.revision != draft.revision ||
        latest.hasUnknownSubmission) {
      context.appWarning(
        latest?.hasUnknownSubmission == true
            ? formDraftUnknownSubmissionMessage
            : '填写内容已变化，请刷新核对',
      );
      return;
    }
    setState(() => _deleting.add(draft.id));
    try {
      await store.delete(draft.id, expectedRevision: draft.revision);
    } on FormDraftUnknownSubmission {
      if (mounted) context.appWarning(formDraftUnknownSubmissionMessage);
    } catch (_) {
      if (mounted) context.appError('草稿删除失败，请重试');
    } finally {
      if (mounted) setState(() => _deleting.remove(draft.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final drafts = ref.watch(formDraftsProvider).where((draft) {
      return (widget.module == null || draft.module == widget.module) &&
          (widget.routePrefix == null ||
              draft.route.startsWith(widget.routePrefix!));
    }).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (drafts.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: ValueKey('form-drafts-panel-${widget.module?.name ?? 'all'}'),
      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: Row(
                  children: [
                    const Icon(Icons.edit_note_rounded, size: 22),
                    const SizedBox(width: UtenSpacing.s8),
                    const Expanded(child: Text('未完成草稿')),
                    UtenNotificationBadge(count: drafts.length),
                    const SizedBox(width: UtenSpacing.s8),
                    Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  ],
                ),
              ),
            ),
            if (_expanded)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: (MediaQuery.sizeOf(context).height * .3).clamp(
                    90.0,
                    240.0,
                  ),
                ),
                child: ListView.builder(
                  primary: false,
                  shrinkWrap: true,
                  itemCount: drafts.length,
                  itemBuilder: (context, index) {
                    final draft = drafts[index];
                    final deleting = _deleting.contains(draft.id);
                    return Padding(
                      key: ValueKey('form-draft-${draft.id}'),
                      padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  draft.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  '保存于 ${ChinaDateTime.formatInstant(draft.updatedAt)}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s8),
                          UtenButton(
                            key: ValueKey('resume-form-draft-${draft.id}'),
                            size: UtenButtonSize.small,
                            onPressed: deleting
                                ? null
                                : () => context.push(draft.resumeLocation),
                            child: const Text('继续填写'),
                          ),
                          IconButton(
                            key: ValueKey('delete-form-draft-${draft.id}'),
                            tooltip: draft.hasUnknownSubmission
                                ? '先核对提交'
                                : '删除草稿',
                            onPressed: deleting || draft.hasUnknownSubmission
                                ? null
                                : () => _delete(draft),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
