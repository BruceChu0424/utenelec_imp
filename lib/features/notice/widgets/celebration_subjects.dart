// 庆典主角组件（V454 聚合祝福卡公共 UI）：
// - CelebrationSubjectsPanel：详情页主角面板（吉祥物 + 全员徽章）。
// - CelebrationSubjectChips：主角姓名徽章行（列表卡紧凑展示，超员折叠 +N）。
// 数据来自 Notice.subjects（服务端 notice_celebration_subjects 快照）；
// 入职周年各人年数不同，徽章逐人带 eventLabel（如 张三 入职5周年）。

import 'package:flutter/material.dart';

import '../../../core/theme/uten_tokens.dart';
import '../models/notice.dart';
import 'celebration_mascot.dart';

/// 详情页主角面板：多主角聚合卡时展示「今日寿星/周年之星」全员名单。
class CelebrationSubjectsPanel extends StatelessWidget {
  const CelebrationSubjectsPanel({super.key, required this.notice});

  final Notice notice;

  String get _header => switch (notice.type) {
    NoticeType.birthday => '今日寿星 · ${notice.subjects.length} 位同事',
    NoticeType.anniversary => '周年之星 · ${notice.subjects.length} 位同事',
    NoticeType.wedding => '新婚之喜 · ${notice.subjects.length} 位同事',
    NoticeType.newborn => '喜添新丁 · ${notice.subjects.length} 位同事',
    _ => '祝福对象 · ${notice.subjects.length} 位',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = notice.type.color;
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: UtenRadius.xlAll,
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CelebrationMascot(type: notice.type, size: 40),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  _header,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          CelebrationSubjectChips(
            subjects: notice.subjects,
            // 周年各人年数不同，徽章逐人标注；生日全员同标签，只列姓名更清爽
            showEventLabel: notice.type == NoticeType.anniversary,
            accent: accent,
          ),
        ],
      ),
    );
  }
}

/// 主角姓名徽章行；超过 [maxChips] 折叠为「+N 位」。
class CelebrationSubjectChips extends StatelessWidget {
  const CelebrationSubjectChips({
    super.key,
    required this.subjects,
    this.showEventLabel = false,
    this.maxChips = 4,
    this.accent,
  });

  final List<NoticeCelebrationSubject> subjects;

  /// 是否逐人展示事件标签（周年场景年数不同时开启）。
  final bool showEventLabel;

  /// 最多展示的徽章数，其余折叠为「+N 位」；null = 不折叠。
  final int? maxChips;

  /// 强调色；空则取主题 primary。
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = accent ?? theme.colorScheme.primary;
    final visible = maxChips == null
        ? subjects
        : subjects.take(maxChips!).toList();
    final overflow = subjects.length - visible.length;
    return Wrap(
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s8,
      children: [
        for (final s in visible)
          _SubjectChip(
            subject: s,
            color: color,
            showEventLabel: showEventLabel,
          ),
        if (overflow > 0)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s12,
              vertical: UtenSpacing.s6,
            ),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '+$overflow 位',
              style: theme.textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}

class _SubjectChip extends StatelessWidget {
  const _SubjectChip({
    required this.subject,
    required this.color,
    required this.showEventLabel,
  });

  final NoticeCelebrationSubject subject;
  final Color color;
  final bool showEventLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s6,
        UtenSpacing.s4,
        UtenSpacing.s12,
        UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: color.withValues(alpha: 0.16),
            child: Text(
              subject.name.isEmpty ? '·' : subject.name.characters.first,
              style: theme.textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          Text(
            subject.name,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (showEventLabel && subject.eventLabel.isNotEmpty) ...[
            const SizedBox(width: UtenSpacing.s6),
            Text(
              subject.eventLabel,
              style: theme.textTheme.labelMedium?.copyWith(color: color),
            ),
          ],
        ],
      ),
    );
  }
}
