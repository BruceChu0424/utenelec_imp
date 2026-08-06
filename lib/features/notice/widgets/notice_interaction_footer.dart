// 通知互动脚（列表卡片底部）：
// - acknowledge 模式：「X 人已收到」+ 收到/已收到 chip（点 chip 直接回执）。
// - bless 模式：「X 条祝福」+ 送上祝福/已送祝福 chip（点 chip 进详情写祝福）。

import 'package:flutter/material.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/notice.dart';

class NoticeInteractionFooter extends StatelessWidget {
  const NoticeInteractionFooter({
    super.key,
    required this.notice,
    required this.onOpenDetail,
    this.onAcknowledge,
  });

  final Notice notice;

  /// 庆典模式：进详情写祝福（或查看本人祝福墙）。
  final VoidCallback onOpenDetail;

  /// 回执模式：直接「点击收到」（列表内一键）。
  final VoidCallback? onAcknowledge;

  @override
  Widget build(BuildContext context) {
    if (notice.interactionMode == NoticeInteractionMode.acknowledge) {
      return _AckRow(notice: notice, onAcknowledge: onAcknowledge);
    }
    if (notice.interactionMode == NoticeInteractionMode.bless) {
      return _BlessRow(notice: notice, onOpenDetail: onOpenDetail);
    }
    return const SizedBox.shrink();
  }
}

class _AckRow extends StatelessWidget {
  const _AckRow({required this.notice, required this.onAcknowledge});

  final Notice notice;
  final VoidCallback? onAcknowledge;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(
          Icons.how_to_reg_outlined,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: UtenSpacing.s4),
        Text(
          l10n.noticeAckCount(notice.ackCount),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const Spacer(),
        if (notice.myAcked || onAcknowledge == null)
          _DoneChip(label: l10n.noticeInteractionReceived)
        else
          ActionChip(
            label: Text(l10n.noticeInteractionReceive),
            avatar: const Icon(Icons.check_rounded, size: 16),
            onPressed: onAcknowledge,
          ),
      ],
    );
  }
}

class _BlessRow extends StatelessWidget {
  const _BlessRow({required this.notice, required this.onOpenDetail});

  final Notice notice;
  final VoidCallback onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final sent = notice.myBlessing != null;
    return Row(
      children: [
        Icon(
          Icons.favorite_rounded,
          size: 16,
          color: notice.type.color,
        ),
        const SizedBox(width: UtenSpacing.s4),
        Text(
          l10n.noticeBlessingCount(notice.blessingCount),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const Spacer(),
        ActionChip(
          label: Text(sent ? l10n.noticeBlessingSent : l10n.noticeSendBlessing),
          avatar: Icon(
            sent ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
            size: 16,
          ),
          onPressed: onOpenDetail,
        ),
      ],
    );
  }
}

class _DoneChip extends StatelessWidget {
  const _DoneChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: UtenRadius.smAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_rounded,
            size: 14,
            color: theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: UtenSpacing.s4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}
