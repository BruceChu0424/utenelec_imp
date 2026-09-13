import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/display_datetime.dart';
import '../models/audit_log_entry.dart';
import '../repositories/audit_log_repository.dart';

class AuditQueryScopeComposer extends StatelessWidget {
  const AuditQueryScopeComposer({
    super.key,
    required this.selectedActor,
    required this.anonymousMode,
    required this.systemAnomalyMode,
    required this.dateRange,
    required this.requestIdController,
    required this.requestInvestigation,
    required this.loading,
    required this.scopeApplied,
    required this.onPickActor,
    required this.onSelectAnonymous,
    required this.onSelectSystemAnomaly,
    required this.onToday,
    required this.onYesterday,
    required this.onSevenDays,
    required this.onThirtyDays,
    required this.onCustomDate,
    required this.onRunQuery,
    required this.onRequestIdChanged,
    required this.onRequestIdSubmitted,
    required this.onClear,
  });

  final AuditActorOption? selectedActor;
  final bool anonymousMode;
  final bool systemAnomalyMode;
  final DateTimeRange? dateRange;
  final TextEditingController requestIdController;
  final bool requestInvestigation;
  final bool loading;
  final bool scopeApplied;
  final VoidCallback onPickActor;
  final VoidCallback onSelectAnonymous;
  final VoidCallback onSelectSystemAnomaly;
  final VoidCallback onToday;
  final VoidCallback onYesterday;
  final VoidCallback onSevenDays;
  final VoidCallback onThirtyDays;
  final VoidCallback onCustomDate;
  final VoidCallback onRunQuery;
  final ValueChanged<String> onRequestIdChanged;
  final ValueChanged<String> onRequestIdSubmitted;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actor = selectedActor;
    final hasActorScope = actor != null || anonymousMode || systemAnomalyMode;
    final range = dateRange;
    final rangeLabel = range == null
        ? '尚未选择日期'
        : ChinaDateTime.formatDate(range.start) ==
              ChinaDateTime.formatDate(range.end)
        ? '${ChinaDateTime.formatDate(range.start)}(单日)'
        : '${ChinaDateTime.formatDate(range.start)} 至 '
              '${ChinaDateTime.formatDate(range.end)}';
    final completedSteps = (hasActorScope ? 1 : 0) + (range != null ? 1 : 0);
    final readyToQuery = hasActorScope && range != null;
    final actorLabel = systemAnomalyMode
        ? '系统异常'
        : anonymousMode
        ? '未识别访问'
        : actor?.primaryLabel ?? '尚未选择人员';
    const scopeButtonStyle = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(0, 48)),
    );

    Widget stepCard({
      required int step,
      required String title,
      required String helper,
      required Widget child,
      required bool complete,
    }) {
      return Container(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        decoration: BoxDecoration(
          color: complete
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.24)
              : theme.colorScheme.surfaceContainerLow,
          borderRadius: UtenRadius.lgAll,
          border: Border.all(
            color: complete
                ? theme.colorScheme.primary.withValues(alpha: 0.45)
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: complete
                        ? theme.colorScheme.primary
                        : theme.colorScheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                  child: complete
                      ? Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: theme.colorScheme.onPrimary,
                        )
                      : Text(
                          '$step',
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              helper,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            child,
          ],
        ),
      );
    }

    final actorStep = stepCard(
      step: 1,
      title: '选择调查对象',
      helper: '可选择人员、未识别访问或系统异常；三种范围互不混合。',
      complete: hasActorScope,
      child: systemAnomalyMode
          ? Row(
              children: [
                const CircleAvatar(
                  child: Icon(Icons.warning_amber_rounded, size: 20),
                ),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '系统异常',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '仅调查失败的系统异常，不包含日常成功自动任务',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(onPressed: onPickActor, child: const Text('改选人员')),
              ],
            )
          : anonymousMode
          ? Row(
              children: [
                const CircleAvatar(
                  child: Icon(Icons.person_off_outlined, size: 20),
                ),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '未识别访问',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '仅查看匿名、认证失败或无法归属人员的访问',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(onPressed: onPickActor, child: const Text('改选人员')),
              ],
            )
          : actor == null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('audit-select-actor'),
                  style: scopeButtonStyle,
                  onPressed: onPickActor,
                  icon: const Icon(Icons.person_search_outlined),
                  label: const Text('选择人员'),
                ),
                const SizedBox(height: UtenSpacing.s8),
                TextButton.icon(
                  key: const ValueKey('audit-select-anonymous'),
                  style: scopeButtonStyle,
                  onPressed: onSelectAnonymous,
                  icon: const Icon(Icons.shield_outlined, size: 18),
                  label: const Text('查看未识别访问'),
                ),
                TextButton.icon(
                  key: const ValueKey('audit-select-system-anomaly'),
                  style: scopeButtonStyle,
                  onPressed: onSelectSystemAnomaly,
                  icon: const Icon(Icons.warning_amber_rounded, size: 18),
                  label: const Text('查看系统异常'),
                ),
              ],
            )
          : Row(
              children: [
                CircleAvatar(child: Text(actor.primaryLabel.characters.first)),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        actor.primaryLabel,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        [
                          if (actor.department?.trim().isNotEmpty == true)
                            actor.department!.trim(),
                          if (actor.position?.trim().isNotEmpty == true)
                            actor.position!.trim(),
                        ].join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(onPressed: onPickActor, child: const Text('更换')),
              ],
            ),
    );

    final dateStep = stepCard(
      step: 2,
      title: '选择查看日期',
      helper: '可查看某一天，或选择最长连续 31 天；全部按北京时间查询。',
      complete: range != null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              OutlinedButton(
                key: const ValueKey('audit-date-today'),
                style: scopeButtonStyle,
                onPressed: hasActorScope ? onToday : null,
                child: const Text('今天'),
              ),
              OutlinedButton(
                key: const ValueKey('audit-date-yesterday'),
                style: scopeButtonStyle,
                onPressed: hasActorScope ? onYesterday : null,
                child: const Text('昨天'),
              ),
              OutlinedButton(
                key: const ValueKey('audit-date-seven-days'),
                style: scopeButtonStyle,
                onPressed: hasActorScope ? onSevenDays : null,
                child: const Text('近 7 天'),
              ),
              OutlinedButton(
                key: const ValueKey('audit-date-thirty-days'),
                style: scopeButtonStyle,
                onPressed: hasActorScope ? onThirtyDays : null,
                child: const Text('近 30 天'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('audit-date-custom'),
                style: scopeButtonStyle,
                onPressed: hasActorScope ? onCustomDate : null,
                icon: const Icon(Icons.date_range_outlined, size: 18),
                label: const Text('自定义区间'),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            rangeLabel,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: range == null
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.primary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );

    final scopeEditor = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 760) {
              return Column(
                children: [
                  actorStep,
                  const SizedBox(height: UtenSpacing.s12),
                  dateStep,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: actorStep),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(child: dateStep),
              ],
            );
          },
        ),
        const SizedBox(height: UtenSpacing.s16),
        LayoutBuilder(
          builder: (context, constraints) {
            final runButton = FilledButton.icon(
              key: const ValueKey('audit-run-query'),
              style: const ButtonStyle(
                minimumSize: WidgetStatePropertyAll(Size(0, 48)),
              ),
              onPressed: !readyToQuery || loading ? null : onRunQuery,
              icon: loading && scopeApplied
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search_rounded),
              label: Text(
                actor != null
                    ? scopeApplied
                          ? '重新加载登录会话'
                          : '查看登录会话'
                    : scopeApplied
                    ? '重新加载操作记录'
                    : '查看操作记录',
              ),
            );
            final hint = Text(
              actor != null
                  ? '按登录会话分页展示；点击会话后再按需加载完整时间线。'
                  : '页面每页 20 条；单次导出最多 10,000 条。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            );
            if (constraints.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  runButton,
                  const SizedBox(height: UtenSpacing.s8),
                  hint,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: hint),
                const SizedBox(width: UtenSpacing.s16),
                runButton,
              ],
            );
          },
        ),
        const SizedBox(height: UtenSpacing.s8),
        ExpansionTile(
          key: const ValueKey('audit-request-investigation'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          leading: const Icon(Icons.account_tree_outlined),
          title: const Text('高级排查：按操作关联编号'),
          subtitle: const Text('仅调查某一次操作及其关联证据时使用'),
          children: [
            Semantics(
              key: const ValueKey('audit-request-id-field'),
              textField: true,
              label: '按操作关联编号精确排查',
              child: UtenSearchBar(
                hint: '输入完整的操作关联编号',
                controller: requestIdController,
                onChanged: onRequestIdChanged,
                onSubmitted: onRequestIdSubmitted,
              ),
            ),
          ],
        ),
      ],
    );

    // A compact investigation header keeps the actual scope controls above the fold.
    final header = Container(
      padding: const EdgeInsets.all(UtenSpacing.s20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(UtenRadius.lg),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: UtenRadius.lgAll,
            ),
            child: Icon(
              Icons.manage_search_rounded,
              color: theme.colorScheme.onPrimary,
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  requestInvestigation
                      ? '关联操作排查'
                      : scopeApplied
                      ? '调查范围已应用'
                      : '建立审计调查范围',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  scopeApplied
                      ? '$actorLabel · $rangeLabel · 全部为北京时间'
                      : AppLocalizations.of(context).auditWorkspaceDescription,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s12),
                Wrap(
                  spacing: UtenSpacing.s12,
                  runSpacing: UtenSpacing.s8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    UtenStatusBadge(
                      label: requestInvestigation
                          ? '精确排查'
                          : scopeApplied
                          ? '已加载范围'
                          : readyToQuery
                          ? '可以查询'
                          : hasActorScope
                          ? '待选日期'
                          : '待选人员',
                      type: requestInvestigation || scopeApplied || readyToQuery
                          ? UtenStatusBadgeType.success
                          : UtenStatusBadgeType.info,
                      icon: requestInvestigation
                          ? Icons.account_tree_outlined
                          : scopeApplied || readyToQuery
                          ? Icons.check_circle_outline_rounded
                          : Icons.pending_outlined,
                    ),
                    if (!scopeApplied && !requestInvestigation)
                      Text(
                        '已完成 $completedSteps / 2 步',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (hasActorScope || range != null || requestInvestigation)
            IconButton(
              tooltip: '重新选择',
              onPressed: loading ? null : onClear,
              icon: const Icon(Icons.restart_alt_rounded),
            ),
        ],
      ),
    );

    return UtenCard(
      padding: EdgeInsets.zero,
      elevation: UtenCardElevation.low,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!scopeApplied || requestInvestigation) ...[
            header,
            const SizedBox(height: UtenSpacing.s16),
          ],
          if (requestInvestigation)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s20,
                0,
                UtenSpacing.s20,
                UtenSpacing.s20,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final copy = Row(
                    children: [
                      Icon(
                        Icons.account_tree_outlined,
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: Text(
                          '正在查看同一操作的完整关联证据',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.onTertiaryContainer,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  );
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(UtenSpacing.s16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.tertiaryContainer,
                      borderRadius: UtenRadius.lgAll,
                    ),
                    child: constraints.maxWidth < 480
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              copy,
                              const SizedBox(height: UtenSpacing.s8),
                              TextButton(
                                onPressed: onClear,
                                child: const Text('返回选人'),
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              Expanded(child: copy),
                              TextButton(
                                onPressed: onClear,
                                child: const Text('返回选人'),
                              ),
                            ],
                          ),
                  );
                },
              ),
            )
          else if (scopeApplied)
            ExpansionTile(
              key: const ValueKey('audit-scope-expansion'),
              tilePadding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s20,
                vertical: UtenSpacing.s4,
              ),
              childrenPadding: const EdgeInsets.fromLTRB(
                UtenSpacing.s20,
                0,
                UtenSpacing.s20,
                UtenSpacing.s20,
              ),
              leading: Icon(
                Icons.tune_rounded,
                color: theme.colorScheme.primary,
              ),
              title: Text(
                '$actorLabel · $rangeLabel',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              children: [scopeEditor],
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s20,
                0,
                UtenSpacing.s20,
                UtenSpacing.s20,
              ),
              child: scopeEditor,
            ),
        ],
      ),
    );
  }
}

class AuditActorPicker extends ConsumerStatefulWidget {
  const AuditActorPicker({super.key});

  @override
  ConsumerState<AuditActorPicker> createState() => _AuditActorPickerState();
}

class _AuditActorPickerState extends ConsumerState<AuditActorPicker> {
  final _controller = TextEditingController();
  final _requests = LatestRequestGuard();
  Timer? _searchDebounce;
  AuditActorPage? _page;
  String _keyword = '';
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load(int page) async {
    final generation = _requests.begin();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(auditLogRepositoryProvider)
          .actors(page: page, keyword: _keyword);
      if (!mounted || !_requests.isCurrent(generation)) return;
      setState(() {
        _page = result;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || !_requests.isCurrent(generation)) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !_requests.isCurrent(generation)) return;
      setState(() {
        _error = '人员列表加载失败，请重试。';
        _loading = false;
      });
    }
  }

  void _searchNow(String value) {
    final keyword = value.trim();
    if (keyword == _keyword) return;
    _keyword = keyword;
    _load(1);
  }

  void _scheduleSearch(String value) {
    _searchDebounce?.cancel();
    if (value.trim().isEmpty) {
      _searchNow('');
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _searchNow(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _page?.items ?? const <AuditActorOption>[];
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s20,
              UtenSpacing.s16,
              UtenSpacing.s8,
              UtenSpacing.s8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '人员目录',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '可选择员工或真实访客；没有操作记录时会显示空结果。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s20),
            child: Semantics(
              textField: true,
              label: '搜索人员姓名、账号或部门',
              child: UtenSearchBar(
                hint: '搜索姓名、账号或部门',
                controller: _controller,
                onInputChanged: (_) => _requests.begin(),
                onChanged: _scheduleSearch,
                autofocus: true,
                // 防抖由本组件的 Timer 统一管理，便于失效旧请求。
                debounce: Duration.zero,
              ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(UtenSpacing.s24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.error_outline_rounded,
                            color: theme.colorScheme.error,
                          ),
                          const SizedBox(height: UtenSpacing.s8),
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: UtenSpacing.s12),
                          OutlinedButton(
                            onPressed: () => _load(_page?.page ?? 1),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  )
                : !_loading && items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(UtenSpacing.s24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.person_off_outlined, size: 40),
                          const SizedBox(height: UtenSpacing.s8),
                          Text(_keyword.isEmpty ? '暂时没有可选择的人员' : '没有找到匹配的人员'),
                          const SizedBox(height: UtenSpacing.s4),
                          Text(
                            '可检查姓名或账号后重新搜索。',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s12,
                      vertical: UtenSpacing.s8,
                    ),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final actor = items[index];
                      final actorKind =
                          actor.actorType == 'visitor' ||
                              actor.department == '外部访客'
                          ? '访客'
                          : '员工';
                      final secondary = [
                        actorKind,
                        if (actor.account?.trim().isNotEmpty == true)
                          '账号 ${actor.account!.trim()}',
                        if (actor.department?.trim().isNotEmpty == true)
                          actor.department!.trim(),
                        if (actor.position?.trim().isNotEmpty == true)
                          actor.position!.trim(),
                      ].join(' · ');
                      return Semantics(
                        button: true,
                        label: '选择 ${actor.primaryLabel}',
                        child: ListTile(
                          key: ValueKey('audit-actor-${actor.actorId}'),
                          minVerticalPadding: UtenSpacing.s12,
                          leading: CircleAvatar(
                            child: Text(actor.primaryLabel.characters.first),
                          ),
                          title: Text(
                            actor.primaryLabel,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (secondary.isNotEmpty) Text(secondary),
                              if (actor.lastActivityAt != null)
                                Text(
                                  '最近操作：${_auditBeijingTime(actor.lastActivityAt)}',
                                ),
                            ],
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.pop(context, actor),
                        ),
                      );
                    },
                  ),
          ),
          if (_page != null)
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: !_loading && _page!.page > 1
                        ? () => _load(_page!.page - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left_rounded),
                    label: const Text('上一页'),
                  ),
                  Expanded(
                    child: Text(
                      '第 ${_page!.page} / ${math.max(_page!.totalPages, 1)} 页',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: !_loading && _page!.page < _page!.totalPages
                        ? () => _load(_page!.page + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right_rounded),
                    label: const Text('下一页'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

String _auditBeijingTime(String? iso) => DisplayDateTime.beijing(
  iso,
  fallback: '时间未知',
).replaceFirst('(北京)', '(北京时间)');
