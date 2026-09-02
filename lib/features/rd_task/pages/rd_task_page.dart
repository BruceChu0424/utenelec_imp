// 工程研发部任务中心（双 Tab：待完成 / 已完成）。
//
//  Tab1 待完成：OPEN/IN_PROGRESS 任务（行/卡片可"标记完成"——需 rd_task:resolve 权限
//               且 allowedActions 含 RESOLVE）。
//  Tab2 已完成：DONE/CANCELED 任务（只读）。
//
// 结构克隆：
//  - operations_workbench_page.dart —— race-guard _load / LayoutBuilder 宽窄分栏
//    （expanded → MasterDataTableView，否则卡片列表）/ connectionRecovery 重载 /
//    _Overview 指标卡（即便为 0 也展示）/ _Filters（关键词 + 类别）/ _MobilePager。
//  - production_board_page.dart —— 双 Tab（SingleTickerProviderStateMixin +
//    TabController(length:2)）+ 懒激活（active + _loadWhenActive + didUpdateWidget），
//    未激活的 Tab 不发请求。
//
// 路由：/rd/tasks → RouteName.rdTaskCenter。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/connection_recovery.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/rd_task.dart';
import '../providers/rd_task_count_provider.dart';
import '../repositories/rd_task_repository.dart';

class RdTaskPage extends ConsumerStatefulWidget {
  const RdTaskPage({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  ConsumerState<RdTaskPage> createState() => _RdTaskPageState();
}

class _RdTaskPageState extends ConsumerState<RdTaskPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late int _activeTab;

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab.clamp(0, 1);
    _tabController = TabController(
      length: 2,
      initialIndex: _activeTab,
      vsync: this,
    )..addListener(_handleTabChange);
  }

  void _handleTabChange() {
    final next = _tabController.index;
    if (next != _activeTab && mounted) {
      setState(() => _activeTab = next);
    }
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_handleTabChange)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: UtenAppBar(
        title: '工程研发部 · 任务中心',
        subtitle: '维护 BOM / 设计 / 打样 / 试产 / ECN 等研发任务',
        leading: UtenBackButton(
          // 本页由工作台卡片 push 进入；无 returnTo 时回到工作台。
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '待完成'),
            Tab(text: '已完成'),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabController,
          children: [
            _RdTaskListPanel(closed: false, active: _activeTab == 0),
            _RdTaskListPanel(closed: true, active: _activeTab == 1),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════ 单 Tab 列表面板（待完成 / 已完成） ═══════════════════════

class _RdTaskListPanel extends ConsumerStatefulWidget {
  const _RdTaskListPanel({required this.closed, required this.active});

  /// true = 已完成 Tab（DONE/CANCELED）；false = 待完成 Tab（OPEN/IN_PROGRESS）。
  final bool closed;

  /// 当前是否处于激活 Tab —— 仅激活后才首次加载（懒激活，避免未访问 Tab 也发请求）。
  final bool active;

  @override
  ConsumerState<_RdTaskListPanel> createState() => _RdTaskListPanelState();
}

class _RdTaskListPanelState extends ConsumerState<_RdTaskListPanel> {
  RdTaskData? _data;
  String? _error;
  bool _loading = true;
  int _page = 1;
  int _requestId = 0;
  String _keyword = '';
  String _category = ''; // '' = 全部类别
  bool _hasLoaded = false;
  bool _resolving = false;

  /// 桌面表格当前选中任务 id（点行触发：既打开 BOM 维护，也据此显示「标记完成」上下文条）。
  String? _selectedTaskId;

  /// 是否有"标记完成"权限（rd_task:resolve 或超管）。仅用于决定是否暴露完成入口；
  /// 行级是否可完成还须看 row.allowedActions。
  bool get _canResolve =>
      ref.read(currentPermissionsProvider).contains(Perm.rdTaskResolve) ||
      ref.read(isSuperAdminProvider);

  /// 当前选中任务的最新行（从本次列表取，任务自动完成离开列表后返回 null → 上下文条自动消失）。
  RdTaskRow? get _selectedRow {
    final id = _selectedTaskId;
    if (id == null || _data == null) return null;
    for (final t in _data!.items) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 点行 / 卡片：打开关联货品的 BOM 维护整页（组装信息 Tab）。
  /// 保存 BOM 后后端经 GOODS_BOM_UPDATED→notifyBomUpdated 自动完成任务并通知计划员；
  /// 故对 BOM 类任务，维护即完成，「标记完成」仅作手动兜底。
  Future<void> _openGoodsBom(RdTaskRow row) async {
    final goodsId = row.goodsId;
    if (goodsId == null || goodsId.isEmpty) {
      context.appInfo('该任务未关联货品，可直接「标记完成」');
      return;
    }
    // 货品详情整页（tab=1 组装信息）；详情拉取/编辑权限由页面自理。
    await context.push(RoutePath.basicinfoGoodsDetail(goodsId, tab: 1));
    // 返回后刷新：BOM 保存触发自动完成经 outbox ~2s，先即时刷一次，再延迟刷一次
    // 让已维护 BOM 的任务自然离开「待完成」（研发不必手动刷新或「标记完成」）。
    if (mounted) {
      ref.read(rdTaskCountProvider.notifier).refresh();
      await _load();
      Future.delayed(const Duration(milliseconds: 2500), () {
        if (mounted) {
          ref.read(rdTaskCountProvider.notifier).refresh();
          _load();
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _loadWhenActive();
  }

  @override
  void didUpdateWidget(covariant _RdTaskListPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _loadWhenActive();
  }

  void _loadWhenActive() {
    if (!widget.active || _hasLoaded) return;
    _hasLoaded = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    if (!mounted) return;
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final next = await ref
          .read(rdTaskRepositoryProvider)
          .load(
            status: widget.closed ? 'done' : 'open',
            category: _category.isEmpty ? null : _category,
            keyword: _keyword.isEmpty ? null : _keyword,
            page: _page,
          );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _data = next;
        _page = next.page;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _error = error is ApiException ? error.message : '研发任务加载失败，请稍后重试';
      });
    }
  }

  void _applyFilter({String? keyword, String? category}) {
    final needsReload = keyword != null || category != null;
    setState(() {
      if (keyword != null) _keyword = keyword;
      if (category != null) _category = category;
      if (needsReload) _page = 1;
    });
    if (needsReload) _load();
  }

  /// 行级"标记完成"是否可用：任务未关闭 + 后端授权 RESOLVE + 当前账号有 resolve 权限。
  bool _resolveEligible(RdTaskRow row) =>
      row.isOpen && row.allowedActions.contains('RESOLVE') && _canResolve;

  /// 点击行 / 卡片"标记完成"按钮：确认弹窗 → 调 resolve → 刷新徽标与本页。
  /// 用 [guardAction] 统一走顶部通知（成功/失败均自动弹条），不再额外 appSuccess 以免重复。
  Future<void> _onResolve(RdTaskRow row) async {
    if (!_resolveEligible(row) || _resolving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('标记任务完成'),
        content: Text('确认将任务 ${row.taskNo}「${row.title}」标记为已完成？'),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          UtenButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认完成'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _resolving = true);
    final ok = await context.guardAction(
      () => ref
          .read(rdTaskRepositoryProvider)
          .resolve(row.id, row.rowVersion, null),
      success: '已标记完成',
      errorFallback: '标记失败，请稍后重试',
    );
    if (!mounted) return;
    setState(() => _resolving = false);
    if (ok == null) return;
    // 任务关闭后徽标计数变化，立即刷新；并重拉本页 + 通知兄弟 Tab（已完成）重拉。
    ref.read(rdTaskCountProvider.notifier).refresh();
    ref.read(rdTaskRefreshTickProvider.notifier).state++;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    // 网络恢复后，不打扰老人、自动重载当前可见 Tab（同 operations_workbench）。
    ref.listen<int>(
      connectionRecoveryProvider.select((state) => state.recoveryEpoch),
      (previous, next) {
        if (next <= (previous ?? 0)) return;
        Future<void>.microtask(_load);
      },
    );
    // 兄弟 Tab 完成/转发后，本 Tab 若已加载过则重拉（已完成 Tab 收新完成任务）。
    ref.listen<int>(rdTaskRefreshTickProvider, (previous, next) {
      if (next > (previous ?? 0) && _hasLoaded) _load();
    });
    return UtenContentContainer.wide(
      padding: const EdgeInsets.only(
        top: UtenSpacing.s16,
        bottom: UtenSpacing.s16,
      ),
      child: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_data == null && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return UtenEmpty.error(
        message: widget.closed ? '无法加载已完成任务' : '无法加载待完成任务',
        description: _error,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    final data = _data;
    if (data == null) {
      return UtenEmpty.error(actionLabel: '重试', onAction: _load);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final breakpoint = breakpointForWidth(constraints.maxWidth);
        // 顶部固定区：指标卡 + 筛选行。
        final top = <Widget>[
          _Overview(
            total: data.total,
            label: widget.closed ? '已完成任务' : '待完成任务',
            tone: widget.closed ? 'success' : 'primary',
          ),
          const SizedBox(height: UtenSpacing.s16),
          _Filters(
            keyword: _keyword,
            category: _category,
            onKeywordChanged: (value) => _applyFilter(keyword: value),
            onCategoryChanged: (value) => _applyFilter(category: value),
            onRefresh: _loading ? null : _load,
          ),
          const SizedBox(height: UtenSpacing.s12),
        ];

        if (breakpoint.isExpanded) {
          final sel = _selectedRow;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...top,
              // 选中可完成任务时，显示「标记完成」上下文条（行点击=开 BOM；完成走这里）。
              if (sel != null && !widget.closed && _resolveEligible(sel))
                _ResolveBar(
                  task: sel,
                  resolving: _resolving,
                  onResolve: () => _onResolve(sel),
                ),
              Expanded(
                child: _DesktopTaskTable(
                  key: const Key('rd-task-desktop-table'),
                  data: data,
                  items: data.items,
                  loading: _loading,
                  onOpenGoods: _openGoodsBom,
                  onSelectionChanged: (row) =>
                      setState(() => _selectedTaskId = row.id),
                  onPageChanged: (page) {
                    setState(() => _page = page);
                    _load();
                  },
                ),
              ),
            ],
          );
        }

        return ListView(
          key: const Key('rd-task-mobile-list'),
          children: [
            ...top,
            if (data.items.isEmpty)
              const SizedBox(
                height: 320,
                child: UtenEmpty(
                  icon: Icons.science_outlined,
                  message: '当前筛选下没有研发任务',
                  description: '可调整类别或关键词筛选后重试。',
                ),
              )
            else
              for (final task in data.items) ...[
                _TaskCard(
                  task: task,
                  onOpenGoods: () => _openGoodsBom(task),
                  onResolve: _resolveEligible(task)
                      ? () => _onResolve(task)
                      : null,
                  resolving: _resolving,
                ),
                const SizedBox(height: UtenSpacing.s12),
              ],
            _MobilePager(
              page: data.page,
              totalPages: data.totalPages,
              loading: _loading,
              onPageChanged: (page) {
                setState(() => _page = page);
                _load();
              },
            ),
          ],
        );
      },
    );
  }
}

// ═══════════════════════ 概览指标卡（单卡，显示 total，即便为 0） ═══════════════════════

class _Overview extends StatelessWidget {
  const _Overview({
    required this.total,
    required this.label,
    required this.tone,
  });

  final int total;
  final String label;
  final String tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _toneColor(tone, theme);
    return SizedBox(
      width: 220,
      child: Semantics(
        label: '$label，$total',
        child: Container(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: UtenRadius.lgAll,
            border: Border.all(color: theme.colorScheme.outlineVariant),
            boxShadow: UtenElevation.low(
              isDark: theme.brightness == Brightness.dark,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: UtenRadius.mdAll,
                ),
                child: Icon(Icons.science_outlined, color: color, size: 22),
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      total.toString(),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                    Text(
                      label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════ 筛选行（关键词 + 类别 + 刷新） ═══════════════════════

class _Filters extends StatelessWidget {
  const _Filters({
    required this.keyword,
    required this.category,
    required this.onKeywordChanged,
    required this.onCategoryChanged,
    required this.onRefresh,
  });

  final String keyword;
  final String category;
  final ValueChanged<String> onKeywordChanged;
  final ValueChanged<String> onCategoryChanged;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < UtenBreakpoints.mediumStart;
        return Wrap(
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: compact ? constraints.maxWidth : 360,
              child: UtenSearchBar(
                key: const Key('rd-task-keyword'),
                initialValue: keyword,
                hint: '搜索任务号、标题、来源单号或货品',
                onChanged: onKeywordChanged,
              ),
            ),
            SizedBox(
              width: compact ? constraints.maxWidth : 200,
              // 固定枚举选项，无孤儿 id 风险，可直接用 DropdownButtonFormField。
              child: DropdownButtonFormField<String>(
                key: const Key('rd-task-category-filter'),
                initialValue: category,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '类别'),
                items: const [
                  DropdownMenuItem(value: '', child: Text('全部类别')),
                  DropdownMenuItem(value: 'BOM', child: Text('BOM维护')),
                  DropdownMenuItem(value: 'DESIGN', child: Text('设计')),
                  DropdownMenuItem(value: 'SAMPLE', child: Text('打样')),
                  DropdownMenuItem(value: 'TRIAL', child: Text('试产')),
                  DropdownMenuItem(value: 'ECN', child: Text('ECN')),
                  DropdownMenuItem(value: 'OTHER', child: Text('其他')),
                ],
                onChanged: (v) => onCategoryChanged(v ?? ''),
              ),
            ),
            if (onRefresh != null)
              IconButton(
                tooltip: '刷新',
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
          ],
        );
      },
    );
  }
}

// ═══════════════════════ 宽屏：MasterDataTableView ═══════════════════════

class _DesktopTaskTable extends StatelessWidget {
  const _DesktopTaskTable({
    super.key,
    required this.data,
    required this.items,
    required this.loading,
    required this.onOpenGoods,
    required this.onSelectionChanged,
    required this.onPageChanged,
  });

  final RdTaskData data;
  final List<RdTaskRow> items;
  final bool loading;

  /// 点行 = 打开关联货品的 BOM 维护弹窗（不是确认完成）。
  final ValueChanged<RdTaskRow> onOpenGoods;

  /// 行被点选时回调（驱动上方「标记完成」上下文条）。
  final ValueChanged<RdTaskRow> onSelectionChanged;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MasterDataTableView<RdTaskRow>(
      columns: [
        MasterColumnDef(
          key: 'taskNo',
          label: '任务号',
          width: 148,
          value: (item) => item.taskNo,
        ),
        MasterColumnDef(
          key: 'category',
          label: '类别',
          width: 110,
          value: (item) => rdTaskCategoryLabel(item.category),
        ),
        const MasterColumnDef(
          key: 'goods',
          label: '货品',
          width: 220,
          value: _goodsText,
        ),
        MasterColumnDef(
          key: 'title',
          label: '标题',
          width: 240,
          value: (item) => item.title,
        ),
        MasterColumnDef(
          key: 'assignee',
          label: '负责人',
          width: 120,
          value: (item) => item.assigneeName,
        ),
        MasterColumnDef(
          key: 'status',
          label: '状态',
          width: 100,
          value: (item) => rdTaskStatusLabel(item.status),
        ),
        MasterColumnDef(
          key: 'priority',
          label: '优先级',
          width: 90,
          value: (item) => _priorityLabel(item.priority),
        ),
        MasterColumnDef(
          key: 'dueDate',
          label: '截止',
          width: 120,
          type: 'date',
          value: (item) => item.dueDate ?? '—',
        ),
        MasterColumnDef(
          key: 'createdAt',
          label: '创建',
          width: 120,
          type: 'date',
          value: (item) => item.createdAt ?? '—',
        ),
      ],
      items: items,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      // 行点击 = 打开关联货品的 BOM 维护弹窗；同时回调选中（驱动上方「标记完成」上下文条）。
      onRowTap: onOpenGoods,
      onSelectionChanged: onSelectionChanged,
      rowColor: (item) => item.priority.toUpperCase() == 'URGENT'
          ? theme.colorScheme.error.withValues(alpha: 0.06)
          : null,
      isLoading: loading,
      emptyMessage: '当前筛选下没有研发任务',
      currentPage: data.page,
      totalPages: data.totalPages,
      onPageChange: onPageChanged,
    );
  }
}

// ═══════════════════════ 窄屏：卡片 ═══════════════════════

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.onOpenGoods,
    required this.onResolve,
    required this.resolving,
  });

  final RdTaskRow task;

  /// 卡片点击 = 打开关联货品的 BOM 维护弹窗。
  final VoidCallback onOpenGoods;

  /// 非空 = 底部"标记完成"按钮可点；null = 不渲染完成按钮。
  final VoidCallback? onResolve;

  /// 是否有任务正在标记完成中（用于禁用按钮，避免重复提交）。
  final bool resolving;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final urgent = task.priority.toUpperCase() == 'URGENT';
    final statusColor = _statusColor(task.status, theme);
    final goods = _goodsText(task);
    return Material(
      color: task.isOpen && urgent
          ? theme.colorScheme.error.withValues(alpha: 0.04)
          : theme.colorScheme.surface,
      borderRadius: UtenRadius.lgAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpenGoods,
        child: Container(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          decoration: BoxDecoration(
            borderRadius: UtenRadius.lgAll,
            border: Border.all(
              color: urgent
                  ? theme.colorScheme.error.withValues(alpha: 0.5)
                  : theme.colorScheme.outlineVariant,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s4),
                        Text(
                          '${task.taskNo} · ${rdTaskCategoryLabel(task.category)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _StatusPill(
                    label: rdTaskStatusLabel(task.status),
                    color: statusColor,
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              Wrap(
                spacing: UtenSpacing.s12,
                runSpacing: UtenSpacing.s8,
                children: [
                  if (goods != null && goods.isNotEmpty)
                    _TaskFact(icon: Icons.inventory_2_outlined, label: goods),
                  _TaskFact(
                    icon: Icons.person_outline_rounded,
                    label: task.assigneeName ?? '未指派',
                  ),
                  if ((task.dueDate ?? '').isNotEmpty)
                    _TaskFact(
                      icon: Icons.event_outlined,
                      label: task.dueDate!,
                      color: urgent ? theme.colorScheme.error : null,
                    ),
                  if (urgent)
                    _StatusPill(label: '紧急', color: theme.colorScheme.error),
                ],
              ),
              if (onResolve != null) ...[
                const SizedBox(height: UtenSpacing.s16),
                UtenButton(
                  key: Key('rd-task-resolve-${task.id}'),
                  onPressed: resolving ? null : onResolve,
                  icon: Icons.check_circle_outline_rounded,
                  isExpanded: true,
                  child: Text(resolving ? '处理中…' : '标记完成'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 桌面表格上方「标记完成」上下文条：点选某条可完成任务后出现。
/// 与行点击（打开 BOM 维护）解耦——完成是手动兜底（BOM 保存即自动完成）。
class _ResolveBar extends StatelessWidget {
  const _ResolveBar({
    required this.task,
    required this.resolving,
    required this.onResolve,
  });

  final RdTaskRow task;
  final bool resolving;
  final VoidCallback onResolve;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s8,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
          borderRadius: UtenRadius.mdAll,
        ),
        child: Row(
          children: [
            Icon(
              Icons.task_alt_rounded,
              size: 18,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                '已选中 ${task.taskNo} · ${task.title}',
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            UtenButton(
              size: UtenButtonSize.small,
              onPressed: resolving ? null : onResolve,
              icon: Icons.check_circle_outline_rounded,
              child: Text(resolving ? '处理中…' : '标记完成'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: UtenRadius.pillAll,
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _TaskFact extends StatelessWidget {
  const _TaskFact({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: c),
        const SizedBox(width: UtenSpacing.s4),
        Text(label, style: TextStyle(color: c)),
      ],
    );
  }
}

class _MobilePager extends StatelessWidget {
  const _MobilePager({
    required this.page,
    required this.totalPages,
    required this.loading,
    required this.onPageChanged,
  });

  final int page;
  final int totalPages;
  final bool loading;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    if (totalPages <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          UtenButton(
            size: UtenButtonSize.small,
            type: UtenButtonType.ghost,
            onPressed: !loading && page > 1
                ? () => onPageChanged(page - 1)
                : null,
            child: const Text('上一页'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
            child: Text('$page / $totalPages'),
          ),
          UtenButton(
            size: UtenButtonSize.small,
            type: UtenButtonType.ghost,
            onPressed: !loading && page < totalPages
                ? () => onPageChanged(page + 1)
                : null,
            child: const Text('下一页'),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════ 辅助：取值/配色 ═══════════════════════

/// 货品文案（编码 + 名称）；两者皆空返回 null（单元格留空）。
String? _goodsText(RdTaskRow item) {
  final parts = <String>[
    if ((item.goodsCode ?? '').isNotEmpty) item.goodsCode!,
    if ((item.goodsName ?? '').isNotEmpty) item.goodsName!,
  ];
  return parts.isEmpty ? null : parts.join(' ');
}

String _priorityLabel(String priority) {
  switch (priority.toUpperCase()) {
    case 'URGENT':
      return '紧急';
    case 'NORMAL':
    default:
      return '普通';
  }
}

Color _statusColor(String status, ThemeData theme) {
  switch (status) {
    case 'OPEN':
      return theme.colorScheme.primary;
    case 'IN_PROGRESS':
      return Colors.orange;
    case 'DONE':
      return UtenColors.success;
    case 'CANCELED':
      return theme.colorScheme.onSurfaceVariant;
    default:
      return theme.colorScheme.primary;
  }
}

Color _toneColor(String tone, ThemeData theme) {
  return switch (tone.toLowerCase()) {
    'success' || 'ready' => UtenColors.success,
    'warning' || 'attention' => UtenColors.warning,
    'error' || 'danger' || 'critical' => theme.colorScheme.error,
    'info' => UtenColors.info,
    _ => theme.colorScheme.primary,
  };
}
