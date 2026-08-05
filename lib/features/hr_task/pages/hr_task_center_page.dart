// HR 任务中心页（行政与人力资源部）：转正/生日/入职周年/新入职集中提醒。
// 数据全部来自服务端按「今天」动态计算（/api/org/hr-tasks/summary），前端不重算。
// 入口：工作台「行政与人力资源部」分区「任务中心」卡片（带 60s 轮询徽标）。
// 文档：docs/03-页面/HR任务中心.md
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/hr_task_summary.dart';
import '../providers/hr_task_count_provider.dart';
import '../repositories/hr_task_repository.dart';

class HrTaskCenterPage extends ConsumerStatefulWidget {
  const HrTaskCenterPage({super.key});

  @override
  ConsumerState<HrTaskCenterPage> createState() => _HrTaskCenterPageState();
}

class _HrTaskCenterPageState extends ConsumerState<HrTaskCenterPage> {
  HrTaskSummary? _summary;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await ref.read(hrTaskRepositoryProvider).summary();
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载任务提醒失败，请稍后重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = UtenEmpty.error(
        message: _error,
        actionLabel: '重试',
        onAction: _load,
      );
    } else {
      body = _buildBody(context, _summary!);
    }
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }
    return Scaffold(
      appBar: UtenAppBar(
        title: '任务中心',
        showBackButton: true,
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () {
              _load();
              ref.read(hrTaskCountProvider.notifier).refresh();
            },
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _buildBody(BuildContext context, HrTaskSummary s) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _confirmSection(context, s),
          _birthdaySection(context, s),
          _anniversarySection(context, s),
          _newHireSection(context, s),
        ],
      ),
    );
  }

  // ---- 转正提醒：逾期（红）→ 今日 → 30 天内 ----
  Widget _confirmSection(BuildContext context, HrTaskSummary s) {
    final items = <_RowSpec>[
      for (final it in s.confirmOverdue)
        _RowSpec(it, '逾期 ${it.days} 天', _ChipTone.danger),
      for (final it in s.confirmToday)
        _RowSpec(it, '今日转正', _ChipTone.warning),
      for (final it in s.confirmUpcoming)
        _RowSpec(it, '${it.days} 天后', _ChipTone.normal),
    ];
    return _SectionCard(
      icon: Icons.how_to_reg_outlined,
      title: '转正提醒',
      subtitle: '试用期 ${s.probationMonths} 个月口径，按入职日期推算',
      emptyText: '近期没有待转正的员工',
      items: items,
      footer: s.unconfirmedLegacyCount > 0
          ? '另有 ${s.unconfirmedLegacyCount} 名入职满一年的老员工未登记转正日期，'
              '请在员工档案中补录。'
          : null,
      onTapItem: (it) => _openEmployee(context, it),
      dateOf: (it) => '预计 ${it.date}',
    );
  }

  // ---- 生日提醒：今日 → 30 天内 ----
  Widget _birthdaySection(BuildContext context, HrTaskSummary s) {
    final items = <_RowSpec>[
      for (final it in s.birthdayToday)
        _RowSpec(it, '今日生日 · ${it.days} 周岁', _ChipTone.warning),
      for (final it in s.birthdayUpcoming)
        _RowSpec(it, '${it.days} 天后', _ChipTone.normal),
    ];
    return _SectionCard(
      icon: Icons.cake_outlined,
      title: '生日提醒',
      emptyText: '近 30 天没有员工生日',
      items: items,
      onTapItem: (it) => _openEmployee(context, it),
      dateOf: (it) => it.date == null ? null : '${it.date!.substring(5)} 生日',
    );
  }

  // ---- 入职周年 ----
  Widget _anniversarySection(BuildContext context, HrTaskSummary s) {
    final items = <_RowSpec>[
      for (final it in s.anniversaryToday)
        _RowSpec(it, '入职满 ${it.days} 年', _ChipTone.warning),
    ];
    return _SectionCard(
      icon: Icons.emoji_events_outlined,
      title: '入职周年',
      emptyText: '今天没有入职周年的员工',
      items: items,
      onTapItem: (it) => _openEmployee(context, it),
      dateOf: (it) => it.date == null ? null : '${it.date} 入职',
    );
  }

  // ---- 新近入职（30 天） ----
  Widget _newHireSection(BuildContext context, HrTaskSummary s) {
    final items = <_RowSpec>[
      for (final it in s.newHires)
        _RowSpec(
          it,
          it.days == 0 ? '今日入职' : '已入职 ${it.days} 天',
          it.days <= 7 ? _ChipTone.warning : _ChipTone.normal,
        ),
    ];
    return _SectionCard(
      icon: Icons.person_add_alt_outlined,
      title: '新近入职',
      subtitle: '近 30 天入职，注意适应期跟进',
      emptyText: '近 30 天没有新入职员工',
      items: items,
      onTapItem: (it) => _openEmployee(context, it),
      dateOf: (it) => it.date == null ? null : '${it.date} 入职',
    );
  }

  void _openEmployee(BuildContext context, HrTaskItem it) {
    context.push('/employee/${it.employeeId}');
  }
}

// ============================================================
// 内部组件
// ============================================================

enum _ChipTone { danger, warning, normal }

class _RowSpec {
  const _RowSpec(this.item, this.chip, this.tone);

  final HrTaskItem item;
  final String chip;
  final _ChipTone tone;
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.emptyText,
    required this.items,
    required this.onTapItem,
    this.subtitle,
    this.footer,
    this.dateOf,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String emptyText;
  final List<_RowSpec> items;
  final String? footer;
  final String? Function(HrTaskItem item)? dateOf;
  final void Function(HrTaskItem item) onTapItem;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s12,
        UtenSpacing.s12,
        0,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s12,
              UtenSpacing.s16,
              UtenSpacing.s8,
            ),
            child: Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (items.isNotEmpty)
                  Text(
                    '${items.length} 条',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s16,
                0,
                UtenSpacing.s16,
                UtenSpacing.s8,
              ),
              child: Text(
                subtitle!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s16,
                UtenSpacing.s4,
                UtenSpacing.s16,
                UtenSpacing.s16,
              ),
              child: Text(
                emptyText,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
              _TaskRow(
                spec: items[i],
                dateText: dateOf?.call(items[i].item),
                onTap: () => onTapItem(items[i].item),
              ),
            ],
          if (footer != null)
            Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.5,
              ),
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Text(
                footer!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.spec, this.dateText, required this.onTap});

  final _RowSpec spec;
  final String? dateText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final it = spec.item;
    final (bg, fg) = switch (spec.tone) {
      _ChipTone.danger => (
        theme.colorScheme.errorContainer,
        theme.colorScheme.onErrorContainer,
      ),
      _ChipTone.warning => (
        theme.colorScheme.tertiaryContainer,
        theme.colorScheme.onTertiaryContainer,
      ),
      _ChipTone.normal => (
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurfaceVariant,
      ),
    };
    final subtitle = [
      it.code,
      ?it.deptName,
      ?it.positionName,
      ?dateText,
      ?it.note,
    ].join(' · ');
    return ListTile(
      onTap: onTap,
      title: Text(it.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          spec.chip,
          style: theme.textTheme.labelSmall?.copyWith(
            color: fg,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
