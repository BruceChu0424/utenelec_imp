part of 'admin_audit_log_page.dart';

final _auditRetentionHintProvider = FutureProvider.autoDispose<String>((
  ref,
) async {
  try {
    final settings = await ref.watch(publicSettingsRepositoryProvider).fetch();
    return '日志分为在线与冷归档两段保留；本页面只查询在线记录。超过在线期后需走受控调查/恢复流程查询归档；'
        '总保留期最长 ${settings.auditReceiptRetentionMonths} 个月，在线与归档分段以系统设置为准。';
  } catch (_) {
    return '本页面只查询在线审计记录；超过在线期的记录进入冷归档，'
        '需要通过受控调查/恢复流程查询。';
  }
});

/// 列表底部的保留策略说明，让"为什么查不到很早的日志"有明确答案。
class _AuditRetentionHint extends ConsumerWidget {
  const _AuditRetentionHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hint = ref.watch(_auditRetentionHintProvider);
    return hint.maybeWhen(
      data: (text) => UtenCard(
        variant: UtenCardVariant.outlined,
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: UtenRadius.mdAll,
              ),
              child: Icon(
                Icons.auto_delete_outlined,
                size: 20,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '留存与归档',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    text,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _AuditMetricGrid extends StatelessWidget {
  const _AuditMetricGrid({
    required this.summary,
    required this.selectedOperation,
    required this.selectedRisk,
    required this.selectedOutcome,
    required this.selectedCategory,
    required this.onAll,
    required this.onRisk,
    required this.onCritical,
    required this.onFailure,
    required this.onDataChange,
  });

  final AuditSummary? summary;
  final String? selectedOperation;
  final String? selectedRisk;
  final String? selectedOutcome;
  final String? selectedCategory;
  final VoidCallback onAll;
  final VoidCallback onRisk;
  final VoidCallback onCritical;
  final VoidCallback onFailure;
  final VoidCallback onDataChange;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cards = [
      _MetricSpec(
        '全部操作',
        summary?.total,
        Icons.receipt_long_outlined,
        theme.colorScheme.primary,
        selectedRisk == null &&
            selectedOutcome == null &&
            selectedOperation == null &&
            selectedCategory == null,
        onAll,
      ),
      _MetricSpec(
        '风险行为',
        summary?.riskCount,
        Icons.warning_amber_rounded,
        theme.colorScheme.tertiary,
        selectedRisk == 'risky',
        onRisk,
      ),
      _MetricSpec(
        '严重风险',
        summary?.criticalCount,
        Icons.gpp_bad_outlined,
        theme.colorScheme.error,
        selectedRisk == 'critical',
        onCritical,
      ),
      _MetricSpec(
        '失败操作',
        summary?.failedCount,
        Icons.error_outline_rounded,
        theme.colorScheme.error,
        selectedOutcome == 'failure',
        onFailure,
      ),
      _MetricSpec(
        '写操作',
        summary?.dataChangeCount,
        Icons.data_object_rounded,
        theme.colorScheme.secondary,
        selectedOperation == 'write',
        onDataChange,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1100
            ? 5
            : constraints.maxWidth >= 720
            ? 3
            : constraints.maxWidth >= 300
            ? 2
            : 1;
        const gap = UtenSpacing.s8;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前调查范围概览',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),

            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final card in cards)
                  SizedBox(
                    width: width,
                    child: _AuditMetricCard(
                      spec: card,
                      compact: constraints.maxWidth < 600,
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _AuditMetricCard extends StatelessWidget {
  const _AuditMetricCard({required this.spec, this.compact = false});

  final _MetricSpec spec;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: spec.selected,
      label: '${spec.label} ${spec.value ?? '加载中'}，点击筛选具体记录',
      child: UtenCard(
        padding: EdgeInsets.all(compact ? UtenSpacing.s12 : UtenSpacing.s16),
        onTap: spec.onTap,
        child: compact
            ? Row(
                children: [
                  Icon(
                    spec.selected ? Icons.check_circle_outline : spec.icon,
                    size: 18,
                    color: spec.color,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(spec.label, style: theme.textTheme.labelLarge),
                  ),
                  Text(
                    spec.value?.toString() ?? '—',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: spec.selected ? spec.color : null,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              )
            : SizedBox(
                height: 82,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: spec.color.withValues(alpha: 0.12),
                            borderRadius: UtenRadius.mdAll,
                          ),
                          child: Icon(spec.icon, size: 19, color: spec.color),
                        ),
                        const Spacer(),
                        if (spec.selected)
                          Icon(
                            Icons.check_circle_rounded,
                            size: 18,
                            color: spec.color,
                          ),
                      ],
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Text(
                            spec.label,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Text(
                          spec.value?.toString() ?? '—',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: spec.selected ? spec.color : null,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _MetricSpec {
  const _MetricSpec(
    this.label,
    this.value,
    this.icon,
    this.color,
    this.selected,
    this.onTap,
  );

  final String label;
  final int? value;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
}

class _AuditFilterPanel extends StatelessWidget {
  const _AuditFilterPanel({
    required this.searchController,
    required this.actionFilter,
    required this.operationKindFilter,
    required this.targetTypeFilter,
    required this.eventSourceFilter,
    required this.categoryFilter,
    required this.riskFilter,
    required this.outcomeFilter,
    required this.actionChips,
    required this.operationChips,
    required this.targetTypeChips,
    required this.eventSourceOptions,
    required this.categoryChips,
    required this.onSearchChanged,
    required this.onActionChanged,
    required this.onOperationKindChanged,
    required this.onTargetTypeChanged,
    required this.onEventSourceChanged,
    required this.onCategoryChanged,
    required this.onRiskChanged,
    required this.onOutcomeChanged,
    required this.onClear,
  });

  final TextEditingController searchController;
  final String? actionFilter;
  final String? operationKindFilter;
  final String? targetTypeFilter;
  final String? eventSourceFilter;
  final String? categoryFilter;
  final String? riskFilter;
  final String? outcomeFilter;
  final List<(String, String?)> actionChips;
  final List<(String, String?)> operationChips;
  final List<(String, String?)> targetTypeChips;
  final List<(String, String?)> eventSourceOptions;
  final List<(String, String?)> categoryChips;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String?> onActionChanged;
  final ValueChanged<String?> onOperationKindChanged;
  final ValueChanged<String?> onTargetTypeChanged;
  final ValueChanged<String?> onEventSourceChanged;
  final ValueChanged<String?> onCategoryChanged;
  final ValueChanged<String?> onRiskChanged;
  final ValueChanged<String?> onOutcomeChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeLabels = <String>[];
    void describe(String? value, List<(String, String?)> options) {
      if (value == null) return;
      for (final option in options) {
        if (option.$2 == value) activeLabels.add(option.$1);
      }
    }

    describe(operationKindFilter, operationChips);
    describe(targetTypeFilter, targetTypeChips);
    describe(categoryFilter, categoryChips);
    describe(eventSourceFilter, eventSourceOptions);
    describe(actionFilter, actionChips);
    describe(riskFilter, const [
      ('有风险', 'risky'),
      ('严重', 'critical'),
      ('高风险', 'high'),
      ('需关注', 'medium'),
      ('低风险', 'low'),
    ]);
    describe(outcomeFilter, const [('成功', 'success'), ('失败', 'failure')]);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.filter_alt_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: UtenSpacing.s8),
              Text(
                '进一步筛选',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: onClear,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('重置'),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          Semantics(
            key: const ValueKey('audit-keyword-field'),
            textField: true,
            label: '在当前人员和日期内搜索',
            child: UtenSearchBar(
              hint: '搜索业务编号、对象编号或操作关联编号',
              controller: searchController,
              onChanged: onSearchChanged,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '搜索只在当前人员和所选日期内生效，不会扩大查询范围。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          if (activeLabels.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  for (final label in activeLabels)
                    UtenStatusBadge(
                      label: label,
                      type: UtenStatusBadgeType.info,
                    ),
                ],
              ),
            ),
          ExpansionTile(
            key: const ValueKey('audit-event-filters'),
            tilePadding: EdgeInsets.zero,
            title: Text(AppLocalizations.of(context).auditFiltersTitle),
            children: [
              const SizedBox(height: UtenSpacing.s16),
              _AuditFilterChoiceGroup(
                title: '操作类型',
                semanticPrefix: '操作类型',
                keyPrefix: 'audit-operation',
                value: operationKindFilter,
                options: operationChips,
                onChanged: onOperationKindChanged,
              ),
              const SizedBox(height: UtenSpacing.s16),
              _AuditFilterChoiceGroup(
                title: '业务对象',
                semanticPrefix: '业务对象',
                keyPrefix: 'audit-target',
                value: targetTypeFilter,
                options: targetTypeChips,
                onChanged: onTargetTypeChanged,
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                '查货品或分类记录时，先选业务对象，再选新增、修改或删除。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s16),
              _AuditFilterChoiceGroup(
                title: '事件类型',
                semanticPrefix: '事件类型',
                keyPrefix: 'audit-category',
                value: categoryFilter,
                options: categoryChips,
                onChanged: onCategoryChanged,
              ),
              const SizedBox(height: UtenSpacing.s16),
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _AuditFilterMenu(
                    label: '事件来源',
                    value: eventSourceFilter,
                    options: eventSourceOptions,
                    onChanged: onEventSourceChanged,
                  ),
                  _AuditFilterMenu(
                    label: '动作分类',
                    value: actionFilter,
                    options: actionChips,
                    onChanged: onActionChanged,
                  ),
                  _AuditFilterMenu(
                    label: '风险等级',
                    value: riskFilter,
                    options: const [
                      ('全部风险', null),
                      ('有风险', 'risky'),
                      ('严重', 'critical'),
                      ('高风险', 'high'),
                      ('需关注', 'medium'),
                      ('低风险', 'low'),
                    ],
                    onChanged: onRiskChanged,
                  ),
                  _AuditFilterMenu(
                    label: '操作结果',
                    value: outcomeFilter,
                    options: const [
                      ('全部结果', null),
                      ('成功', 'success'),
                      ('失败', 'failure'),
                    ],
                    onChanged: onOutcomeChanged,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AuditFilterChoiceGroup extends StatelessWidget {
  const _AuditFilterChoiceGroup({
    required this.title,
    required this.semanticPrefix,
    required this.keyPrefix,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String title;
  final String semanticPrefix;
  final String keyPrefix;
  final String? value;
  final List<(String, String?)> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: UtenSpacing.s8),
        Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            for (final (label, optionValue) in options)
              Semantics(
                button: true,
                selected: value == optionValue,
                label: '$semanticPrefix：$label',
                child: ChoiceChip(
                  key: ValueKey('$keyPrefix-${optionValue ?? 'all'}'),
                  label: Text(label),
                  selected: value == optionValue,
                  onSelected: (_) => onChanged(optionValue),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _AuditFilterMenu extends StatelessWidget {
  const _AuditFilterMenu({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final List<(String, String?)> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = options.firstWhere(
      (item) => item.$2 == value,
      orElse: () => options.first,
    );
    return PopupMenuButton<String>(
      tooltip: label,
      onSelected: (selectedValue) =>
          onChanged(selectedValue.isEmpty ? null : selectedValue),
      itemBuilder: (context) => [
        for (final option in options)
          PopupMenuItem<String>(
            value: option.$2 ?? '',
            child: Row(
              children: [
                Icon(
                  option.$2 == value
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Text(option.$1),
              ],
            ),
          ),
      ],
      child: Chip(
        avatar: const Icon(Icons.tune_rounded, size: 18),
        label: Text('$label：${selected.$1}'),
      ),
    );
  }
}

class _AuditTrendCard extends StatelessWidget {
  const _AuditTrendCard({required this.points, required this.rangeLabel});

  final List<AuditDailyPoint> points;
  final String rangeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxValue = points.fold<int>(
      1,
      (value, point) => math.max(value, point.total),
    );
    final total = points.fold<int>(0, (value, point) => value + point.total);
    final risks = points.fold<int>(
      0,
      (value, point) => value + point.riskCount,
    );
    return Semantics(
      label: '$rangeLabel 操作趋势，共 $total 次操作，其中 $risks 次风险行为',
      child: UtenCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bar_chart_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    '$rangeLabel 操作趋势',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const UtenStatusBadge(
                  label: '红色为风险行为',
                  type: UtenStatusBadgeType.danger,
                  size: UtenStatusBadgeSize.small,
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s16),
            SizedBox(
              height: 126,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final point in points)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              '${point.total}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                            const SizedBox(height: UtenSpacing.s4),
                            Expanded(
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: FractionallySizedBox(
                                  heightFactor: math.max(
                                    point.total / maxValue,
                                    0.04,
                                  ),
                                  child: ClipRRect(
                                    borderRadius: UtenRadius.smAll,
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        if (point.total - point.riskCount > 0)
                                          Expanded(
                                            flex: point.total - point.riskCount,
                                            child: ColoredBox(
                                              color: theme
                                                  .colorScheme
                                                  .primaryContainer,
                                            ),
                                          ),
                                        if (point.riskCount > 0)
                                          Expanded(
                                            flex: point.riskCount,
                                            child: ColoredBox(
                                              color: theme.colorScheme.error,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: UtenSpacing.s4),
                            Text(
                              point.date.length >= 10
                                  ? point.date.substring(5)
                                  : point.date,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuditViewModeSwitch extends StatelessWidget {
  const _AuditViewModeSwitch({
    required this.sessionMode,
    required this.loading,
    required this.onSession,
    required this.onEvents,
  });

  final bool sessionMode;
  final bool loading;
  final VoidCallback onSession;
  final VoidCallback onEvents;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Semantics(
        label: sessionMode ? '当前按登录会话查看' : '当前按事件明细查看',
        child: SegmentedButton<bool>(
          key: const ValueKey('audit-view-mode'),
          // 统一分段范式：选中只变背景色不出 ✓。
          showSelectedIcon: false,
          segments: [
            ButtonSegment<bool>(
              value: true,
              enabled: !loading,
              icon: const Icon(Icons.login_rounded),
              label: const Text('登录会话'),
            ),
            ButtonSegment<bool>(
              value: false,
              enabled: !loading,
              icon: const Icon(Icons.list_alt_rounded),
              label: const Text('事件明细'),
            ),
          ],
          selected: {sessionMode},
          onSelectionChanged: (selection) {
            if (selection.single) {
              onSession();
            } else {
              onEvents();
            }
          },
        ),
      ),
    );
  }
}

class _AuditSessionOverview extends StatelessWidget {
  const _AuditSessionOverview({required this.page});

  final AuditSessionPage page;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final operations = page.items.fold<int>(
      0,
      (total, item) => total + item.operationCount,
    );
    final attentionSessions = page.items.where((item) {
      final status = item.status.trim().toLowerCase();
      return item.failureCount > 0 ||
          item.postLogoutCount > 0 ||
          status == 'security_terminated' ||
          status == 'activity_after_logout' ||
          status == 'revoked' ||
          status == 'interrupted' ||
          status == 'abnormal' ||
          status == 'reuse_detected';
    }).length;
    final specs = [
      _SessionOverviewSpec(
        label: '所选范围会话',
        value: page.total,
        icon: Icons.login_rounded,
        color: theme.colorScheme.primary,
      ),
      _SessionOverviewSpec(
        label: '本页人工操作',
        value: operations,
        icon: Icons.touch_app_outlined,
        color: theme.colorScheme.secondary,
      ),
      _SessionOverviewSpec(
        label: '本页需核查会话',
        value: attentionSessions,
        icon: attentionSessions > 0
            ? Icons.warning_amber_rounded
            : Icons.verified_user_outlined,
        color: attentionSessions > 0
            ? theme.colorScheme.error
            : theme.colorScheme.primary,
      ),
    ];
    return UtenCard(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          Widget fact(_SessionOverviewSpec spec) => Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s4,
              vertical: UtenSpacing.s8,
            ),
            child: Row(
              children: [
                Icon(spec.icon, size: 18, color: spec.color),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(spec.label, style: theme.textTheme.labelLarge),
                ),
                Text(
                  '${spec.value}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: spec.color,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          );
          if (constraints.maxWidth < 600) {
            return Column(children: [for (final spec in specs) fact(spec)]);
          }
          return Row(
            children: [for (final spec in specs) Expanded(child: fact(spec))],
          );
        },
      ),
    );
  }
}

class _SessionOverviewSpec {
  const _SessionOverviewSpec({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });
  final String label;
  final int value;
  final IconData icon;
  final Color color;
}

class _AuditSessionListHeader extends StatelessWidget {
  const _AuditSessionListHeader({
    required this.total,
    required this.currentPage,
    required this.totalPages,
  });

  final int? total;
  final int? currentPage;
  final int? totalPages;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            total == null ? '正在加载登录会话' : '登录会话 · $total 次',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (currentPage != null && totalPages != null)
          UtenStatusBadge(
            label: '第 $currentPage / ${math.max(totalPages!, 1)} 页',
            type: UtenStatusBadgeType.info,
          ),
      ],
    );
  }
}

class _AuditSessionLoadingList extends StatelessWidget {
  const _AuditSessionLoadingList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget skeletonLine(double width, {double height = 12}) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: UtenRadius.pillAll,
      ),
    );
    return Semantics(
      label: '正在加载登录会话摘要',
      child: Padding(
        padding: const EdgeInsets.only(top: UtenSpacing.s8),
        child: Column(
          children: [
            for (var index = 0; index < 3; index++) ...[
              UtenCard(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: UtenRadius.lgAll,
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          skeletonLine(190, height: 14),
                          const SizedBox(height: UtenSpacing.s12),
                          skeletonLine(280),
                          const SizedBox(height: UtenSpacing.s8),
                          skeletonLine(150),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (index < 2) const SizedBox(height: UtenSpacing.s8),
            ],
          ],
        ),
      ),
    );
  }
}

class _AuditSessionEmptyCard extends StatelessWidget {
  const _AuditSessionEmptyCard({required this.onShowEvents});

  final VoidCallback onShowEvents;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        child: Column(
          children: [
            Icon(
              Icons.history_toggle_off_rounded,
              size: 44,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text('该范围没有可识别的登录会话', style: theme.textTheme.titleMedium),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '旧日志尚无会话标识，可切换事件视图。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s16),
            OutlinedButton.icon(
              key: const ValueKey('audit-session-empty-show-events'),
              onPressed: onShowEvents,
              icon: const Icon(Icons.list_alt_rounded),
              label: const Text('切换事件视图'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuditListHeader extends StatelessWidget {
  const _AuditListHeader({
    required this.total,
    required this.hasDrillDown,
    required this.onClearDrillDown,
  });

  final int total;
  final bool hasDrillDown;
  final VoidCallback onClearDrillDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '操作记录 · $total 条',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        if (hasDrillDown)
          TextButton.icon(
            onPressed: onClearDrillDown,
            icon: const Icon(Icons.close_rounded, size: 18),
            label: const Text('清除卡片筛选'),
          ),
      ],
    );
  }
}

class _AuditEventTile extends StatelessWidget {
  const _AuditEventTile({required this.entry, required this.onTap});

  final AuditLogEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actor = AuditEventPresentation.actorLabel(
      actorDisplay: entry.actorDisplay,
      actorName: entry.actorName,
      actorAccount: entry.actorAccount,
    );
    final department = entry.actorDepartment?.trim();
    final actorContext = department?.isNotEmpty == true
        ? '$actor · $department'
        : actor;
    final time = _AdminAuditLogPageState._fmtTime(entry.createdAt);
    final action = entry.actionLabel?.trim().isNotEmpty == true
        ? entry.actionLabel!.trim()
        : _AdminAuditLogPageState._actionLabel(entry.action);
    final object = entry.objectLabel?.trim().isNotEmpty == true
        ? entry.objectLabel!.trim()
        : _objectTypeLabel(entry.targetType);
    final salesViewNarrative = AuditEventPresentation.salesViewNarrative(
      action: entry.action,
      targetName: entry.targetName,
    );
    final summary =
        salesViewNarrative ??
        (entry.summary?.trim().isNotEmpty == true
            ? entry.summary!
            : object.isNotEmpty
            ? '$action · $object'
            : action);
    final objectEvidence = auditEventObjectEvidence(entry);
    final detailBits = <String>[
      ?objectEvidence,
      if (entry.pageLabel?.trim().isNotEmpty == true) '位置 ${entry.pageLabel}',
      if (entry.deviceLabel?.trim().isNotEmpty == true &&
          entry.deviceLabel != '未提供设备信息')
        '设备 ${entry.deviceLabel}',
    ];
    final failed = _isAuditFailure(entry.result, entry.statusCode);
    final showRisk = entry.riskLevel != 'low';

    Widget outcomeIndicator() {
      if (failed) {
        return _AuditResultBadge(
          result: entry.result,
          resultLabel: entry.resultLabel,
          statusCode: entry.statusCode,
        );
      }
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_outline_rounded,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: UtenSpacing.s4),
          Text(
            _auditOutcomeLabel(
              entry.result,
              entry.resultLabel,
              entry.statusCode,
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    return Semantics(
      button: true,
      excludeSemantics: true,
      label:
          '$actor，在$time，$summary，'
          '${_auditOutcomeLabel(entry.result, entry.resultLabel, entry.statusCode)}，点击查看详情',
      child: UtenCard(
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final icon = _AuditRiskIcon(level: entry.riskLevel);
            final content = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.person_outline_rounded,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s4),
                    Expanded(
                      child: Text(
                        actorContext,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s4),
                Row(
                  children: [
                    Icon(
                      Icons.schedule_rounded,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s4),
                    Expanded(
                      child: Text(
                        time,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  summary,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.45,
                  ),
                ),
                if (detailBits.isNotEmpty) ...[
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    detailBits.join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            );
            final trailing = Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (showRisk) _AuditRiskBadge(level: entry.riskLevel),
                if (showRisk) const SizedBox(height: UtenSpacing.s8),
                outcomeIndicator(),
              ],
            );
            if (constraints.maxWidth < 660) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      icon,
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(child: content),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  Row(
                    children: [
                      if (showRisk) _AuditRiskBadge(level: entry.riskLevel),
                      if (showRisk) const SizedBox(width: UtenSpacing.s8),
                      outcomeIndicator(),
                      const Spacer(),
                      const Icon(Icons.chevron_right_rounded),
                    ],
                  ),
                ],
              );
            }
            return Row(
              children: [
                icon,
                const SizedBox(width: UtenSpacing.s16),
                Expanded(child: content),
                const SizedBox(width: UtenSpacing.s16),
                trailing,
                const SizedBox(width: UtenSpacing.s8),
                const Icon(Icons.chevron_right_rounded),
              ],
            );
          },
        ),
      ),
    );
  }
}

String _shortId(String value) => value.length <= 13
    ? value
    : '${value.substring(0, 8)}…${value.substring(value.length - 4)}';

String _objectTypeLabel(String? value) => switch (value?.trim()) {
  'goods' => '货品',
  'material_categories' => '货品分类',
  'clients' => '客户',
  'suppliers' => '供应商',
  'purchase_orders' => '采购订单',
  'sales_quotes' => '销售报价',
  'sales_orders' => '销售订单',
  'sales_shipments' => '销售出货',
  'sales_other_shipments' => '销售其他出库',
  'sales_returns' => '销售退货',
  'subcontract_orders' => '委外订单',
  'production_plans' => '生产计划',
  'production_execution_segments' => '生产执行分段',
  'employees' => '员工档案',
  'departments' => '部门',
  'users' || 'user_accounts' => '用户账号',
  'system_settings' => '系统设置',
  _ => '',
};

bool _isAuditFailure(String? result, int? statusCode) {
  if (statusCode != null && statusCode >= 400) return true;
  final primaryCode = _auditPrimaryResultCode(result);
  if (primaryCode == null) return false;
  return primaryCode != 'success' && primaryCode != 'succeeded';
}

String? _auditPrimaryResultCode(String? result) {
  final normalized = result?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return null;
  final separator = normalized.indexOf(';');
  final primary = separator < 0
      ? normalized
      : normalized.substring(0, separator).trim();
  return primary.isEmpty ? null : primary;
}

bool _isAuditSuccess(String? result, int? statusCode) {
  if (statusCode != null && statusCode >= 400) return false;
  final primaryCode = _auditPrimaryResultCode(result);
  return primaryCode == 'success' || primaryCode == 'succeeded';
}

String _auditOutcomeLabel(
  String? result,
  String? resultLabel,
  int? statusCode,
) {
  final translated = resultLabel?.trim();
  if (_isAuditFailure(result, statusCode)) {
    if (translated?.isNotEmpty == true && !translated!.contains('成功')) {
      return translated;
    }
    final fallback = _AdminAuditLogPageState._resultLabel(
      _auditPrimaryResultCode(result),
    );
    return fallback.isNotEmpty && fallback != '成功' && fallback != '未知结果'
        ? fallback
        : '失败';
  }
  if (translated?.isNotEmpty == true) return translated!;
  if ((statusCode != null && statusCode >= 200 && statusCode < 400) ||
      _isAuditSuccess(result, statusCode)) {
    return '成功';
  }
  return '未知结果';
}

class _AuditRiskIcon extends StatelessWidget {
  const _AuditRiskIcon({required this.level});

  final String level;

  @override
  Widget build(BuildContext context) {
    final color = _riskColor(context, level);
    final icon = switch (level) {
      'critical' => Icons.gpp_bad_outlined,
      'high' => Icons.warning_amber_rounded,
      'medium' => Icons.info_outline_rounded,
      _ => Icons.check_circle_outline_rounded,
    };
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: UtenRadius.lgAll,
      ),
      child: Icon(icon, color: color),
    );
  }
}

class _AuditRiskBadge extends StatelessWidget {
  const _AuditRiskBadge({required this.level});

  final String level;

  @override
  Widget build(BuildContext context) {
    final type = switch (level) {
      'critical' => UtenStatusBadgeType.danger,
      'high' => UtenStatusBadgeType.danger,
      'medium' => UtenStatusBadgeType.warning,
      _ => UtenStatusBadgeType.success,
    };
    return UtenStatusBadge(
      label: _riskLabel(level),
      type: type,
      icon: level == 'low' ? Icons.check_rounded : Icons.warning_amber_rounded,
      size: UtenStatusBadgeSize.small,
    );
  }
}

class _AuditResultBadge extends StatelessWidget {
  const _AuditResultBadge({
    required this.result,
    required this.statusCode,
    this.resultLabel,
  });

  final String? result;
  final String? resultLabel;
  final int? statusCode;

  @override
  Widget build(BuildContext context) {
    final failed = _isAuditFailure(result, statusCode);
    final label = _auditOutcomeLabel(result, resultLabel, statusCode);
    final succeeded =
        !failed && (_isAuditSuccess(result, statusCode) || label == '成功');
    return UtenStatusBadge(
      label: label,
      type: failed
          ? UtenStatusBadgeType.danger
          : succeeded
          ? UtenStatusBadgeType.success
          : UtenStatusBadgeType.info,
      size: UtenStatusBadgeSize.small,
    );
  }
}

String _riskLabel(String level) => switch (level) {
  'critical' => '严重风险',
  'high' => '高风险',
  'medium' => '需关注',
  _ => '低风险',
};

Color _riskColor(BuildContext context, String level) {
  final colors = Theme.of(context).colorScheme;
  return switch (level) {
    'critical' || 'high' => colors.error,
    'medium' => colors.tertiary,
    _ => colors.primary,
  };
}

class _AuditErrorCard extends StatelessWidget {
  const _AuditErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final copy = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline_rounded, color: theme.colorScheme.error),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '内容加载失败',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '$message。请检查网络后重试，当前调查范围不会丢失。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          final retry = OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          );
          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                copy,
                const SizedBox(height: UtenSpacing.s12),
                retry,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: copy),
              const SizedBox(width: UtenSpacing.s16),
              retry,
            ],
          );
        },
      ),
    );
  }
}

class _AuditEmptyCard extends StatelessWidget {
  const _AuditEmptyCard({required this.onAdjustScope});

  final VoidCallback onAdjustScope;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s40),
      child: Column(
        children: [
          Icon(
            Icons.manage_search_rounded,
            size: 44,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text('没有符合条件的操作记录', style: theme.textTheme.titleMedium),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            '可重置进一步筛选，或重新选择人员和日期区间。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          OutlinedButton.icon(
            onPressed: onAdjustScope,
            icon: const Icon(Icons.manage_search_outlined),
            label: const Text('重新选择人员和日期'),
          ),
        ],
      ),
    );
  }
}

class _AuditPagination extends StatefulWidget {
  const _AuditPagination({
    required this.currentPage,
    required this.totalPages,
    required this.loading,
    required this.onPageChanged,
  });

  final int currentPage;
  final int totalPages;
  final bool loading;
  final ValueChanged<int> onPageChanged;

  @override
  State<_AuditPagination> createState() => _AuditPaginationState();
}

class _AuditPaginationState extends State<_AuditPagination> {
  late final TextEditingController _controller;

  int get _lastPage => math.max(widget.totalPages, 1);

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.currentPage}');
  }

  @override
  void didUpdateWidget(covariant _AuditPagination oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentPage != widget.currentPage &&
        _controller.text != '${widget.currentPage}') {
      _controller.text = '${widget.currentPage}';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _jump() {
    final parsed = int.tryParse(_controller.text.trim());
    if (parsed == null) {
      _controller.text = '${widget.currentPage}';
      return;
    }
    final page = parsed.clamp(1, _lastPage).toInt();
    _controller.text = '$page';
    if (!widget.loading && page != widget.currentPage) {
      widget.onPageChanged(page);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 600) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: '上一页',
            onPressed: !widget.loading && widget.currentPage > 1
                ? () => widget.onPageChanged(widget.currentPage - 1)
                : null,
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          Flexible(
            child: Text(
              '第 ${widget.currentPage} / $_lastPage 页',
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            tooltip: '下一页',
            onPressed: !widget.loading && widget.currentPage < widget.totalPages
                ? () => widget.onPageChanged(widget.currentPage + 1)
                : null,
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      );
    }
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s8,
      children: [
        IconButton(
          tooltip: '上一页',
          onPressed: !widget.loading && widget.currentPage > 1
              ? () => widget.onPageChanged(widget.currentPage - 1)
              : null,
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Text('第 ${widget.currentPage} / $_lastPage 页'),
        SizedBox(
          width: 88,
          child: Semantics(
            textField: true,
            label: '跳转页码，范围 1 到 $_lastPage',
            child: TextField(
              key: const ValueKey('audit-page-jump-field'),
              controller: _controller,
              enabled: !widget.loading,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _jump(),
              decoration: const InputDecoration(labelText: '页码', isDense: true),
            ),
          ),
        ),
        FilledButton.tonal(
          key: const ValueKey('audit-page-jump-button'),
          onPressed: widget.loading ? null : _jump,
          child: const Text('跳转'),
        ),
        IconButton(
          tooltip: '下一页',
          onPressed: !widget.loading && widget.currentPage < widget.totalPages
              ? () => widget.onPageChanged(widget.currentPage + 1)
              : null,
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ],
    );
  }
}

/// Opens the one authoritative four-tab audit detail viewer.
///
/// Both the event list and the login-session timeline use this entry so an
/// investigator always sees the same redacted before/after evidence, related
/// database changes, device evidence and troubleshooting facts.
