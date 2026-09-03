// 建议详情页
// 详情页全断点套 UtenContentContainer.narrow（maxWidth 1120）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/uten_notify.dart';
import '../../../shared/auth/permissions.dart';
import '../models/suggestion.dart';
import '../providers/suggestion_providers.dart';

class SuggestionDetailPage extends ConsumerWidget {
  const SuggestionDetailPage({super.key, required this.suggestionId});
  final String suggestionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(suggestionDetailProvider(suggestionId));

    return Scaffold(
      appBar: const UtenAppBar(title: '建议详情', showBackButton: true),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => UtenEmpty.error(
          message: '加载失败：$e',
          onAction: () =>
              ref.invalidate(suggestionDetailProvider(suggestionId)),
        ),
        data: (s) {
          if (s == null) return const UtenEmpty(message: '建议不存在');
          return _Content(suggestion: s);
        },
      ),
    );
  }
}

class _Content extends ConsumerWidget {
  const _Content({required this.suggestion});
  final Suggestion suggestion;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // 详情页全断点窄版收敛（1120），避免宽屏正文被拉得过长。
    // 正文可框选复制：UtenContentContainer 默认已包局部 SelectionArea（准则 §3.4）。
    return UtenContentContainer.narrow(
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        children: [
          // 类别 + 状态
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s12,
                  vertical: UtenSpacing.s4,
                ),
                decoration: BoxDecoration(
                  color: suggestion.category.color.withValues(alpha: 0.12),
                  borderRadius: UtenRadius.mdAll,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      suggestion.category.icon,
                      size: 14,
                      color: suggestion.category.color,
                    ),
                    const SizedBox(width: UtenSpacing.s4),
                    Text(
                      suggestion.category.label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: suggestion.category.color,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              UtenStatusBadge(
                label: suggestion.status.label,
                type: _statusBadge(suggestion.status),
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          // 标题
          Text(
            suggestion.title,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          // 提交人
          Row(
            children: [
              Icon(
                Icons.account_circle_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: UtenSpacing.s4),
              Text(
                suggestion.displayName,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              Text(
                _fmt(suggestion.submittedAt),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          // 正文
          UtenCard(
            child: SelectableText(
              suggestion.content,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
            ),
          ),

          if (ref
              .watch(currentPermissionsProvider)
              .contains(Perm.suggestionReply)) ...[
            const SizedBox(height: UtenSpacing.s24),
            _ReplyComposer(suggestion: suggestion),
          ],

          // 回复
          if (suggestion.replies.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s24),
            UtenSectionHeader(
              title: '官方回复 (${suggestion.replies.length})',
              icon: Icons.forum_outlined,
            ),
            const SizedBox(height: UtenSpacing.s12),
            for (final reply in suggestion.replies) ...[
              _ReplyCard(reply: reply),
              const SizedBox(height: UtenSpacing.s12),
            ],
          ],

          const SizedBox(height: UtenSpacing.s16),
          // 点赞行
          Center(
            child: Material(
              type: MaterialType.transparency,
              borderRadius: UtenRadius.pillAll,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () async {
                  try {
                    await toggleSuggestionLike(ref, suggestion.id);
                  } catch (error) {
                    if (context.mounted) {
                      UtenNotify.apiError(context, error, fallback: '点赞失败，请重试');
                    }
                  }
                },
                borderRadius: UtenRadius.pillAll,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s24,
                    vertical: UtenSpacing.s12,
                  ),
                  decoration: BoxDecoration(
                    color: suggestion.likedByMe
                        ? UtenColors.error.withValues(alpha: 0.1)
                        : theme.colorScheme.surfaceContainerLow,
                    borderRadius: UtenRadius.pillAll,
                    border: Border.all(
                      color: suggestion.likedByMe
                          ? UtenColors.error
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        suggestion.likedByMe
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 18,
                        color: suggestion.likedByMe
                            ? UtenColors.error
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(
                        '${suggestion.likes} 人赞同',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: suggestion.likedByMe
                              ? UtenColors.error
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  UtenStatusBadgeType _statusBadge(SuggestionStatus s) => switch (s) {
    SuggestionStatus.submitted => UtenStatusBadgeType.info,
    SuggestionStatus.reviewing => UtenStatusBadgeType.warning,
    SuggestionStatus.resolved => UtenStatusBadgeType.success,
    SuggestionStatus.rejected => UtenStatusBadgeType.danger,
  };

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class _ReplyComposer extends ConsumerStatefulWidget {
  const _ReplyComposer({required this.suggestion});

  final Suggestion suggestion;

  @override
  ConsumerState<_ReplyComposer> createState() => _ReplyComposerState();
}

class _ReplyComposerState extends ConsumerState<_ReplyComposer> {
  final _contentController = TextEditingController();
  SuggestionStatus? _newStatus;

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const UtenSectionHeader(
            title: '官方回复',
            icon: Icons.admin_panel_settings_outlined,
          ),
          const SizedBox(height: UtenSpacing.s12),
          TextField(
            key: const ValueKey('suggestion-reply-content'),
            controller: _contentController,
            minLines: 3,
            maxLines: 8,
            maxLength: 5000,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(
              labelText: '回复内容 *',
              hintText: '说明处理结论、后续安排或未采纳原因',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          if (_nextStatuses.isNotEmpty)
            UtenDropdownField(
              label: '同步更新状态',
              value: _newStatus?.name,
              searchable: false,
              hintText: '保持当前状态(${widget.suggestion.status.label})',
              items: [
                for (final status in _nextStatuses)
                  UtenDropdownItem(value: status.name, label: status.label),
              ],
              onChanged: (value) => setState(() {
                _newStatus = SuggestionStatus.values
                    .where((status) => status.name == value)
                    .firstOrNull;
              }),
            )
          else
            Text(
              '当前为终态(${widget.suggestion.status.label})，可继续补充回复，但不能回退或切换处理状态。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: UtenSpacing.s16),
          Align(
            alignment: Alignment.centerRight,
            child: UtenActionButton(
              key: const ValueKey('suggestion-reply-submit'),
              icon: Icons.send_rounded,
              label: const Text('发布回复'),
              loadingLabel: const Text('发布中…'),
              onAction: _submit,
            ),
          ),
        ],
      ),
    );
  }

  List<SuggestionStatus> get _nextStatuses =>
      switch (widget.suggestion.status) {
        SuggestionStatus.submitted => const [SuggestionStatus.reviewing],
        SuggestionStatus.reviewing => const [
          SuggestionStatus.resolved,
          SuggestionStatus.rejected,
        ],
        SuggestionStatus.resolved ||
        SuggestionStatus.rejected => const <SuggestionStatus>[],
      };

  Future<void> _submit() async {
    final content = _contentController.text.trim();
    if (content.isEmpty) {
      UtenNotify.warning(context, '请填写回复内容');
      return;
    }
    try {
      await replyToSuggestion(
        ref,
        id: widget.suggestion.id,
        content: content,
        newStatus: _newStatus,
      );
      if (!mounted) return;
      _contentController.clear();
      setState(() => _newStatus = null);
      UtenNotify.success(context, '官方回复已发布');
    } catch (error) {
      if (mounted) UtenNotify.apiError(context, error, fallback: '发布回复失败');
    }
  }
}

class _ReplyCard extends StatelessWidget {
  const _ReplyCard({required this.reply});
  final SuggestionReply reply;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: UtenColors.teal500.withValues(alpha: 0.06),
        borderRadius: UtenRadius.lgAll,
        border: const Border(
          left: BorderSide(color: UtenColors.teal500, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: UtenColors.teal600.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.verified_rounded,
                  size: 16,
                  color: UtenColors.teal600,
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      reply.replier,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      _fmt(reply.repliedAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            reply.content,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
          ),
        ],
      ),
    );
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
