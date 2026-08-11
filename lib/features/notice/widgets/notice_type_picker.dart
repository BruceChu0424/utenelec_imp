// 通知类型选择器（分组：公告广播 / 庆典祝福）
// 替代原发布页的 DropdownButtonFormField——按类型分组、瓦片化、带图标色与一句描述。

import 'package:flutter/material.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/notice.dart';

/// 通知类型标签（i18n；广播 5 类 + 庆典 4 类全覆盖）。
String noticeTypeLabel(AppLocalizations l10n, NoticeType type) =>
    switch (type) {
      NoticeType.announcement => l10n.noticeTypeAnnouncement,
      NoticeType.policy => l10n.noticeTypePolicy,
      NoticeType.benefit => l10n.noticeTypeBenefit,
      NoticeType.system => l10n.noticeTypeSystem,
      NoticeType.urgent => l10n.noticeTypeUrgent,
      NoticeType.birthday => l10n.noticeTypeBirthday,
      NoticeType.anniversary => l10n.noticeTypeAnniversary,
      NoticeType.wedding => l10n.noticeTypeWedding,
      NoticeType.newborn => l10n.noticeTypeNewborn,
      _ => type.label,
    };

String _noticeTypeDesc(AppLocalizations l10n, NoticeType type) =>
    switch (type) {
      NoticeType.announcement => l10n.noticeTypeAnnouncementDesc,
      NoticeType.policy => l10n.noticeTypePolicyDesc,
      NoticeType.benefit => l10n.noticeTypeBenefitDesc,
      NoticeType.system => l10n.noticeTypeSystemDesc,
      NoticeType.urgent => l10n.noticeTypeUrgentDesc,
      NoticeType.birthday => l10n.noticeTypeBirthdayDesc,
      NoticeType.anniversary => l10n.noticeTypeAnniversaryDesc,
      NoticeType.wedding => l10n.noticeTypeWeddingDesc,
      NoticeType.newborn => l10n.noticeTypeNewbornDesc,
      _ => type.label,
    };

/// 触发器形态：只读输入框样式（图标 + 当前类型 + 下拉箭头），点击拉开底部选择器。
class NoticeTypePicker extends StatelessWidget {
  const NoticeTypePicker({
    super.key,
    required this.current,
    required this.available,
    required this.onChanged,
    this.enabled = true,
  });

  final NoticeType current;
  final List<NoticeType> available;
  final ValueChanged<NoticeType> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return InkWell(
      onTap: enabled ? () => _open(context) : null,
      borderRadius: UtenRadius.smAll,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: l10n.noticePublishTypeLabel,
          prefixIcon: Icon(current.icon, color: current.color),
          border: const OutlineInputBorder(),
        ),
        child: Row(
          children: [
            Expanded(child: Text(noticeTypeLabel(l10n, current))),
            const Icon(Icons.arrow_drop_down_rounded),
          ],
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final chosen = await showModalBottomSheet<NoticeType>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TypeSheet(available: available, current: current),
    );
    if (chosen != null) onChanged(chosen);
  }
}

class _TypeSheet extends StatelessWidget {
  const _TypeSheet({required this.available, required this.current});

  final List<NoticeType> available;
  final NoticeType current;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final broadcast = available
        .where((t) => !t.isCelebratory && !t.isWork)
        .toList();
    final celebration = available.where((t) => t.isCelebratory).toList();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          UtenSpacing.s16,
          UtenSpacing.s8,
          UtenSpacing.s16,
          UtenSpacing.s16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
              child: Text(
                l10n.noticePublishTypeLabel,
                style: theme.textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (broadcast.isNotEmpty)
                      _Group(
                        title: l10n.noticeGroupBroadcast,
                        types: broadcast,
                        current: current,
                      ),
                    if (celebration.isNotEmpty) ...[
                      const SizedBox(height: UtenSpacing.s16),
                      _Group(
                        title: l10n.noticeGroupCelebration,
                        types: celebration,
                        current: current,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({
    required this.title,
    required this.types,
    required this.current,
  });

  final String title;
  final List<NoticeType> types;
  final NoticeType current;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: UtenSpacing.s4,
            bottom: UtenSpacing.s8,
          ),
          child: Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            for (final type in types)
              _TypeTile(
                type: type,
                selected: type == current,
                label: noticeTypeLabel(l10n, type),
                desc: _noticeTypeDesc(l10n, type),
              ),
          ],
        ),
      ],
    );
  }
}

class _TypeTile extends StatelessWidget {
  const _TypeTile({
    required this.type,
    required this.selected,
    required this.label,
    required this.desc,
  });

  final NoticeType type;
  final bool selected;
  final String label;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => Navigator.of(context).pop(type),
      borderRadius: UtenRadius.mdAll,
      child: Container(
        width: 180,
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: selected
              ? type.color.withValues(alpha: 0.08)
              : theme.colorScheme.surfaceContainerLow,
          borderRadius: UtenRadius.mdAll,
          border: Border.all(
            color: selected ? type.color : theme.colorScheme.outlineVariant,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(UtenSpacing.s4),
                  decoration: BoxDecoration(
                    color: type.color.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(type.icon, size: 18, color: type.color),
                ),
                const Spacer(),
                if (selected)
                  Icon(Icons.check_circle_rounded, size: 20, color: type.color),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              label,
              style: theme.textTheme.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              desc,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
