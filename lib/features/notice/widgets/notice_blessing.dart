// 通知详情互动区：
// - acknowledge 模式：「点击收到」按钮 + N 人已收到 + 近期收到人。
// - bless 模式：送上祝福 composer（模板 chips + 输入 + 发送）+ 近期祝福 + 查看全部（祝福墙）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/notice.dart';
import '../providers/notice_providers.dart';

/// 系统默认祝福模板（与后端一致；仅 {name} 占位符）。
const Map<NoticeType, List<String>> kDefaultBlessingTemplates = {
  NoticeType.birthday: [
    '{name}，祝你生日快乐，万事如意！',
    '{name}，生日快乐！愿你新的一岁所求皆所愿。',
    '{name}，祝你生日快乐，工作顺利，笑口常开！',
  ],
  NoticeType.anniversary: [
    '{name}，入职周年快乐！感谢一路同行。',
    '{name}，感谢你与公司并肩作战，周年快乐！',
    '{name}，祝你入职周年快乐，前程似锦！',
  ],
  NoticeType.wedding: [
    '{name}，新婚快乐，百年好合！',
    '{name}，祝你们永结同心，幸福美满！',
    '{name}，新婚大喜，甜甜蜜蜜！',
  ],
  NoticeType.newborn: [
    '{name}，恭喜喜添新丁，阖家幸福！',
    '{name}，祝宝宝健康成长，万事顺意！',
    '{name}，恭喜！愿小宝贝快乐无忧。',
  ],
};

/// 详情页互动区入口（按 notice.interactionMode 分派）。
class NoticeInteractionSection extends ConsumerWidget {
  const NoticeInteractionSection({super.key, required this.notice});

  final Notice notice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (notice.interactionMode == NoticeInteractionMode.acknowledge) {
      return _AckSection(notice: notice);
    }
    if (notice.interactionMode == NoticeInteractionMode.bless) {
      return _BlessSection(notice: notice);
    }
    return const SizedBox.shrink();
  }
}

class _AckSection extends ConsumerWidget {
  const _AckSection({required this.notice});

  final Notice notice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return UtenCard(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.how_to_reg_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  notice.myAcked
                      ? l10n.noticeAckYouAndCount(notice.ackCount)
                      : l10n.noticeAckCount(notice.ackCount),
                  style: theme.textTheme.titleSmall,
                ),
              ],
            ),
            if (notice.recentAckers.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s12),
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  for (final name in notice.recentAckers)
                    Chip(
                      avatar: const Icon(Icons.person_rounded, size: 16),
                      label: Text(name),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
            const SizedBox(height: UtenSpacing.s16),
            if (notice.myAcked)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_rounded,
                      color: theme.colorScheme.primary),
                  const SizedBox(width: UtenSpacing.s8),
                  Text(l10n.noticeInteractionReceived,
                      style: theme.textTheme.bodyMedium),
                ],
              )
            else
              UtenActionButton(
                isExpanded: true,
                icon: Icons.check_circle_outline_rounded,
                label: Text(l10n.noticeClickToReceive),
                onAction: () async {
                  await acknowledgeNotice(ref, notice.id);
                  if (context.mounted) {
                    context.appSuccess(l10n.noticeInteractionReceived);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _BlessSection extends ConsumerStatefulWidget {
  const _BlessSection({required this.notice});

  final Notice notice;

  @override
  ConsumerState<_BlessSection> createState() => _BlessSectionState();
}

class _BlessSectionState extends ConsumerState<_BlessSection> {
  final _controller = TextEditingController();

  List<String> get _templates {
    final curated = widget.notice.blessingTemplates;
    if (curated.isNotEmpty) return curated;
    return kDefaultBlessingTemplates[widget.notice.type] ?? const [];
  }

  String _resolved(String template) =>
      template.replaceAll('{name}', widget.notice.subjectName ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final notice = widget.notice;
    return UtenCard(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.favorite_rounded, color: notice.type.color),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  l10n.noticeBlessingWall,
                  style: theme.textTheme.titleSmall,
                ),
                const Spacer(),
                Text(
                  l10n.noticeBlessingCount(notice.blessingCount),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s16),
            if (_templates.isNotEmpty) ...[
              Text(
                l10n.noticeBlessingTemplatesTitle,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  for (final template in _templates)
                    ActionChip(
                      label: Text(_resolved(template)),
                      onPressed: () {
                        _controller.text = _resolved(template);
                        _controller.selection = TextSelection(
                          baseOffset: _controller.text.length,
                          extentOffset: _controller.text.length,
                        );
                      },
                    ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
            ],
            TextField(
              controller: _controller,
              minLines: 2,
              maxLines: 5,
              maxLength: 200,
              decoration: InputDecoration(
                hintText: l10n.noticeBlessingPlaceholder,
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenActionButton(
              isExpanded: true,
              icon: Icons.send_rounded,
              label: Text(
                notice.myBlessing != null
                    ? l10n.noticeBlessingSent
                    : l10n.noticeBlessingSendButton,
              ),
              loadingLabel: Text(l10n.noticeBlessingSending),
              onAction: () async {
                final text = _controller.text.trim();
                if (text.isEmpty) {
                  context.appError(l10n.noticeBlessingValidateEmpty);
                  throw Exception('empty'); // 保持按钮解锁
                }
                await blessNotice(ref, notice.id, text);
                _controller.clear();
                if (context.mounted) {
                  context.appSuccess(l10n.noticeBlessingSent);
                }
              },
            ),
            if (notice.recentBlessings.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s20),
              UtenSectionHeader(
                title: l10n.noticeBlessingReceivedCount(notice.blessingCount),
                icon: Icons.card_giftcard_rounded,
              ),
              const SizedBox(height: UtenSpacing.s8),
              for (final b in notice.recentBlessings) ...[
                _BlessingCard(blessing: b),
                const SizedBox(height: UtenSpacing.s8),
              ],
              if (notice.blessingCount > notice.recentBlessings.length)
                Center(
                  child: TextButton.icon(
                    onPressed: () => _showWall(context, ref),
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: Text(l10n.noticeBlessingViewAll(notice.blessingCount)),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  void _showWall(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _BlessingWallSheet(noticeId: widget.notice.id),
    );
  }
}

class _BlessingCard extends StatelessWidget {
  const _BlessingCard({required this.blessing});

  final NoticeBlessing blessing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: blessing.mine
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(
          color: blessing.mine
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(
                  Icons.person_rounded,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Text(
                blessing.senderName,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (blessing.mine) ...[
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  '(我)',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
              const Spacer(),
              Text(
                _fmt(blessing.createdAt),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(blessing.content, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _BlessingWallSheet extends ConsumerWidget {
  const _BlessingWallSheet({required this.noticeId});

  final String noticeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final async = ref.watch(noticeBlessingsProvider(noticeId));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          UtenSpacing.s16,
          UtenSpacing.s8,
          UtenSpacing.s16,
          UtenSpacing.s16,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.8,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                child: Text(
                  l10n.noticeBlessingWall,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => UtenEmpty.error(
                    message: '$e',
                    onAction: () =>
                        ref.invalidate(noticeBlessingsProvider(noticeId)),
                  ),
                  data: (items) {
                    if (items.isEmpty) {
                      return UtenEmpty(
                        icon: Icons.favorite_outline_rounded,
                        message: l10n.noticeBlessingWallEmpty,
                      );
                    }
                    return ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, i) => Padding(
                        padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                        child: _BlessingCard(blessing: items[i]),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _fmt(DateTime d) {
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
