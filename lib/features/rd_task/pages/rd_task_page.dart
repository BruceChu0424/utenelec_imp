// 工程研发部任务中心(三分段: 待处理 / 进行中 / 已完成)。
//
//  待处理 OPEN        —— 还没人开工, 红徽章: 轮到研发动手。
//  进行中 IN_PROGRESS —— 已经在做、还没交, 黄徽章(ADR-100): 在办但此刻不用催。
//  已完成 DONE/CANCELED —— 终态只读, 不挂数。
//
// 2026-09-21 把裸 TabBar「待完成 / 已完成」换成 UtenFilterToolbar 三分段: 原来
// OPEN 与 IN_PROGRESS 混在「待完成」一段里, 黄色数字点进去没有落脚的地方, 用户
// 也分不清「没人接」和「有人在做」。分段拆开后两个数字各自可点开核对。
// 行/卡片可「标记完成」——需 rd_task:resolve 权限且 allowedActions 含 RESOLVE。
//
// 2026-09-09 表格化收尾：宽屏 MasterDataTableView 的「状态」「类别」两列接入
// 真实 autofilter——bucket 从当前页行前端聚合（参照 material_analysis_material_table），
// 行集在前端裁剪（服务端仍按 keyword/category/页码分页）；关键词/类别下拉等
// 服务端口径变化时列筛选随之清空。窄屏卡片布局不动。
//
// 结构克隆：
//  - operations_workbench_page.dart —— race-guard _load / LayoutBuilder 宽窄分栏
//    （expanded → MasterDataTableView，否则卡片列表）/ connectionRecovery 重载 /
//    _Overview 指标卡（即便为 0 也展示）/ _Filters（关键词 + 类别）/ _MobilePager。
//
// 路由：/rd/tasks → RouteName.rdTaskCenter。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/connection_recovery.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/rd_task.dart';
import '../providers/rd_task_count_provider.dart';
import '../repositories/rd_task_repository.dart';
import '../../../shared/badges/badge_registry.dart';

/// 任务中心的三个分段 —— 值同时是列表接口的 `status` 过滤参数。
///
/// 后端 `RdTaskService.scopeStatuses` 的白名单: `pending` = 只 OPEN,
/// `in_progress` = 只 IN_PROGRESS, `done` = DONE/CANCELED; 默认值 `open` 是
/// 两档合集, 留给老调用点, 本页三段都不用它。**改了这里就要同步后端白名单**,
/// 这三个字符串是本页与服务端之间唯一的契约。
enum _RdTaskSeg {
  pending('pending', '待处理'),
  inProgress('in_progress', '进行中'),
  done('done', '已完成');

  const _RdTaskSeg(this.apiStatus, this.label);

  /// 列表接口 `status` 查询参数。
  final String apiStatus;
  final String label;

  /// 终态段: 只读浏览, 不挂任何计数。
  bool get isClosed => this == _RdTaskSeg.done;
}

class RdTaskPage extends ConsumerStatefulWidget {
  const RdTaskPage({super.key, this.initialTab = 0});

  /// 旧入口的 Tab 序号(0 = 未完成, 1 = 已完成); 未完成落在「待处理」段。
  final int initialTab;

  @override
  ConsumerState<RdTaskPage> createState() => _RdTaskPageState();
}

class _RdTaskPageState extends ConsumerState<RdTaskPage> {
  late _RdTaskSeg _seg;

  @override
  void initState() {
    super.initState();
    _seg = widget.initialTab == 1 ? _RdTaskSeg.done : _RdTaskSeg.pending;
  }

  @override
  Widget build(BuildContext context) {
    // 红 = 待处理(OPEN): 没人开工, 轮到研发动手。
    // 黄 = 进行中(IN_PROGRESS): 已认领在做, 此刻不用催。
    //
    // 2026-09-21: 两个数各读服务端一个字段, 不再用「count 减 inProgress」还原 open。
    // 相减有两处毛病: 卡面红徽章读的同一个 count 含 inProgress, 等于让黄色那批被红黄
    // 两条链各数一次(ADR-100 禁止的双计); 而且两支 provider 各自 60s 轮询、起拍时刻不同,
    // 一次 OPEN→IN_PROGRESS 跃迁后最长会偏 1 直到下次对齐。
    final pendingCount = ref.watch(
      badgeEntryTodoProvider(BadgeEntry.rdTaskCenter),
    );
    final inProgressCount = ref.watch(
      badgeEntryInProgressProvider(BadgeEntry.rdTaskCenter),
    );
    return Scaffold(
      appBar: UtenAppBar(
        title: '工程研发部 · 任务中心',
        subtitle: '维护 BOM / 设计 / 打样 / 试产 / ECN 等研发任务',
        leading: UtenBackButton(
          // 本页由工作台卡片 push 进入；无 returnTo 时回到工作台。
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 全平台统一筛选工具条替代裸 TabBar(纯分类形态, 搜索框在下方筛选行)。
            UtenContentContainer.wide(
              selectable: false,
              padding: const EdgeInsets.only(top: UtenSpacing.s12),
              child: UtenFilterToolbar<_RdTaskSeg>(
                segmentsKey: const Key('rd-task-segments'),
                segments: [
                  UtenFilterSegment(
                    value: _RdTaskSeg.pending,
                    label: _RdTaskSeg.pending.label,
                    count: pendingCount < 0 ? 0 : pendingCount,
                    countForm: UtenSegmentCountForm.actionable,
                  ),
                  UtenFilterSegment(
                    value: _RdTaskSeg.inProgress,
                    label: _RdTaskSeg.inProgress.label,
                    count: inProgressCount,
                    countForm: UtenSegmentCountForm.inProgress,
                  ),
                  // 终态只读, 不挂数(准则 §二: 历史集合不喊人)。
                  UtenFilterSegment(
                    value: _RdTaskSeg.done,
                    label: _RdTaskSeg.done.label,
                  ),
                ],
                selected: {_seg},
                onSelectionChanged: (value) => setState(() => _seg = value),
              ),
            ),
            Expanded(child: _RdTaskListPanel(seg: _seg)),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════ 单分段列表面板(待处理 / 进行中 / 已完成) ═══════════════════════

class _RdTaskListPanel extends ConsumerStatefulWidget {
  const _RdTaskListPanel({required this.seg});

  /// 当前分段 —— 决定列表的 `status` 过滤与「标记完成」入口是否出现。
  final _RdTaskSeg seg;

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

  /// 宽屏表格「状态/类别」列的表头筛选状态（key=列 key，value=选中值；
  /// null/移除=清除）。bucket 从当前页行前端聚合、行集前端裁剪；服务端
  /// 关键词/类别口径变化时随之清空（同批次一分段切换清列筛选的口径）。
  final Map<String, String?> _tableFilters = {};

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
      refreshBadges(ref);
      await _load();
      Future.delayed(const Duration(milliseconds: 2500), () {
        if (mounted) {
          refreshBadges(ref);
          _load();
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _scheduleFirstLoad();
  }

  @override
  void didUpdateWidget(covariant _RdTaskListPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换分段 = 换服务端口径: 回到第一页, 并清掉按旧行集聚合的表头筛选。
    // 关键词与类别刻意保留 —— 用户常常拿同一个条件在三段之间来回看。
    if (widget.seg != oldWidget.seg) {
      _page = 1;
      _tableFilters.clear();
      _selectedTaskId = null;
      _load();
    }
  }

  void _scheduleFirstLoad() {
    if (_hasLoaded) return;
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
            status: widget.seg.apiStatus,
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
      if (needsReload) {
        _page = 1;
        // 服务端筛选口径变了，表头列筛选（针对旧行集聚合）随之失效。
        _tableFilters.clear();
      }
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
    refreshBadges(ref);
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
    // 本人或他人完成/转发任务后重拉: 完成的单会离开「待处理」「进行中」而落进
    // 「已完成」, 三段谁也别停在旧快照上。
    ref.listen<int>(rdTaskRefreshTickProvider, (previous, next) {
      if (next > (previous ?? 0) && _hasLoaded) _load();
    });
    return UtenContentContainer.wide(
      // 轮询页不包选择区：研发任务徽章定时刷新（结构性闪现）与拖选并发有
      // CME 风险（准则 §3.4，用户口径：轮询页不包）。
      selectable: false,
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
        message: '无法加载${widget.seg.label}任务',
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
            label: '${widget.seg.label}任务',
            // 指标卡配色跟着分段语义走: 待处理沿用主色, 进行中用琥珀(与黄徽章
            // 同一族), 已完成绿色。
            tone: switch (widget.seg) {
              _RdTaskSeg.done => 'success',
              _RdTaskSeg.inProgress => 'warning',
              _RdTaskSeg.pending => 'primary',
            },
          ),
          const SizedBox(height: UtenSpacing.s16),
          _Filters(
            keyword: _keyword,
            category: _category,
            onKeywordChanged: (value) => _applyFilter(keyword: value),
            onCategoryChanged: (value) => _applyFilter(category: value),
            onRefresh: _loading
                ? null
                : () {
                    setState(() => _page = 1);
                    _load();
                  },
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
              if (sel != null && !widget.seg.isClosed && _resolveEligible(sel))
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
                  filters: _tableFilters,
                  onFilterChanged: (key, value) => setState(() {
                    if (value == null) {
                      _tableFilters.remove(key); // 选「所有」= 不筛
                    } else {
                      _tableFilters[key] = value;
                    }
                  }),
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
              child: UtenDropdownField(
                key: const Key('rd-task-category-filter'),
                label: '类别',
                value: category,
                allowClear: false,
                items: const [
                  UtenDropdownItem(value: '', label: '全部类别'),
                  UtenDropdownItem(value: 'BOM', label: 'BOM维护'),
                  UtenDropdownItem(value: 'DESIGN', label: '设计'),
                  UtenDropdownItem(value: 'SAMPLE', label: '打样'),
                  UtenDropdownItem(value: 'TRIAL', label: '试产'),
                  UtenDropdownItem(value: 'ECN', label: 'ECN'),
                  UtenDropdownItem(value: 'OTHER', label: '其他'),
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
    required this.filters,
    required this.onFilterChanged,
    required this.onOpenGoods,
    required this.onSelectionChanged,
    required this.onPageChanged,
  });

  final RdTaskData data;
  final List<RdTaskRow> items;
  final bool loading;

  /// 「状态/类别」列的表头筛选状态（页面持有；null/移除=清除）。
  final Map<String, String?> filters;
  final void Function(String key, String? value) onFilterChanged;

  /// 点行 = 打开关联货品的 BOM 维护弹窗（不是确认完成）。
  final ValueChanged<RdTaskRow> onOpenGoods;

  /// 行被点选时回调（驱动上方「标记完成」上下文条）。
  final ValueChanged<RdTaskRow> onSelectionChanged;
  final ValueChanged<int> onPageChanged;

  /// 按表头筛选裁剪当前页行集（空值行在选了任何值时被滤掉，与物料分析表一致）。
  List<RdTaskRow> _applyFilters(List<RdTaskRow> rows) {
    if (filters.values.every((v) => v == null || v.isEmpty)) return rows;
    final status = filters['status'];
    final category = filters['category'];
    return rows.where((row) {
      final statusOk =
          status == null ||
          status.isEmpty ||
          rdTaskStatusLabel(row.status) == status;
      final categoryOk =
          category == null ||
          category.isEmpty ||
          rdTaskCategoryLabel(row.category) == category;
      return statusOk && categoryOk;
    }).toList();
  }

  /// 状态/类别两列的筛选桶：当前页全量行聚合（筛选前），空值行不进桶。
  Map<String, List<MasterFacetBucket>> _facetsOf(List<RdTaskRow> rows) {
    List<MasterFacetBucket> bucketsOf(Iterable<String> texts) {
      final counts = <String, int>{};
      for (final text in texts) {
        if (text.isEmpty) continue;
        counts[text] = (counts[text] ?? 0) + 1;
      }
      final entries = counts.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      return [
        for (final entry in entries)
          MasterFacetBucket(value: entry.key, count: entry.value),
      ];
    }

    return {
      'status': bucketsOf(rows.map((row) => rdTaskStatusLabel(row.status))),
      'category': bucketsOf(
        rows.map((row) => rdTaskCategoryLabel(row.category)),
      ),
    };
  }

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
        // 货品身份格：主行名称、副行编号。研发任务多是「同名不同编号」的 BOM /
        // 打样件（V5 插面自制与委外两条），旧写法把编号和名称挤在一行且编号在前，
        // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
        // 颜色取 RdTaskRow.colorName（后端 join 货品主档色）：同名同编号的货品
        // 按颜色分行是常态，少了颜色照样认错货。
        MasterColumnDef(
          key: 'goods',
          label: '货品名称',
          width: 200,
          value: (item) => item.goodsName ?? item.goodsCode,
          cellBuilderHandlesSemantics: true,
          cellBuilder: (_, item) => UtenGoodsIdentityCell(name: item.goodsName),
        ),
        MasterColumnDef(
          key: 'goodsCode',
          label: '编号',
          width: 130,
          value: (item) => UtenGoodsAttributeCell.text(item.goodsCode),
          cellBuilder: (_, item) => UtenGoodsAttributeCell(item.goodsCode),
        ),
        MasterColumnDef(
          key: 'colorName',
          label: '颜色',
          width: 96,
          value: (item) => UtenGoodsAttributeCell.text(item.colorName),
          cellBuilder: (_, item) => UtenGoodsAttributeCell(item.colorName),
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
      items: _applyFilters(items),
      // 表头筛选（2026-09-09）：bucket 从当前页全量行聚合，行集在前端裁剪，
      // 与服务端 keyword/类别下拉分页叠加。
      facets: _facetsOf(items),
      nullCounts: const {},
      filters: filters,
      onFilterChanged: onFilterChanged,
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
