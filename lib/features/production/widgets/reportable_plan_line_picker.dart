import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_panel_header.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../components/layout/uten_picker_footer_layout.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/paging/scoped_paged_read_view_mixin.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/reportable_plan_line.dart';
import '../repositories/production_repository.dart';

/// 选择本次报工对应的生产子任务（2026-09-11 起**支持多选**）。
///
/// 桌面端右侧滑入（外壳 showUtenAdaptivePanel，带面板投影；browse 档 75% 屏宽、840 小屏下限），
/// 手机端底部全屏；数据只来自服务端“可报工计划”读侧，不在客户端猜
/// 计划号或销售订单分摊。
///
/// 返回**按点选顺序**的列表：调用方把第一条填进当前行，其余各开一行
/// （用户原话：「新建生产日报里面应该可以多选，现在只是单选」）。
/// 取消/关闭返回 null；确认但一条没选返回空列表不可能发生（确认键会禁用）。
Future<List<ReportablePlanLine>?> showReportablePlanLinePicker(
  BuildContext context,
  WidgetRef ref, {
  String? departmentId,
  String? executionSegmentId,
}) {
  return showUtenAdaptivePanel<List<ReportablePlanLine>>(
    context: context,
    compactHeightFactor: 0.94,
    drawerWidth: 840,
    panelElevation: 12,
    builder: (_) => _ReportablePlanLineSheet(
      departmentId: departmentId,
      executionSegmentId: executionSegmentId,
    ),
  );
}

class _ReportablePlanLineSheet extends ConsumerStatefulWidget {
  const _ReportablePlanLineSheet({this.departmentId, this.executionSegmentId});

  final String? departmentId;
  final String? executionSegmentId;

  @override
  ConsumerState<_ReportablePlanLineSheet> createState() =>
      _ReportablePlanLineSheetState();
}

class _ReportablePlanLineSheetState
    extends ConsumerState<_ReportablePlanLineSheet>
    with ScopedPagedReadViewMixin<_ReportablePlanLineSheet> {
  final _search = TextEditingController();
  final _tableRows = MasterDataTableRowsController<ReportablePlanLine>();
  List<ReportablePlanLine>? _items;
  String? _error;
  String _keyword = '';
  bool _loading = true;
  int _requestGeneration = 0;
  int _page = 1;
  int _retryPage = 1;
  int _totalPages = 1;
  int _total = 0;

  @override
  void scopedPagedReadOwnerChanged() => setState(() {
    _requestGeneration++;
    _tableRows.update(const []);
    _items = null;
    _picked.clear();
    _error = scopedPagedReadRejection?.message;
    _loading = false;
    _page = 1;
    _retryPage = 1;
    _totalPages = 1;
    _total = 0;
  });

  /// 已点选（高亮）的计划行，**按点选先后保序**；底部「确定」才 pop 返回
  /// （二次操作契约）。保序是因为调用方按这个顺序建行，用户点的顺序=行序。
  final List<ReportablePlanLine> _picked = [];

  /// 一个计划行可同时包含多个销售分摊和品质恢复授权，必须分别选择并保留来源。
  String _lineKey(ReportablePlanLine item) => [
    item.planItemId,
    item.executionSegmentId ?? '',
    item.executionSegmentSalesAllocationId ?? '',
    item.orderItemId ?? '',
    item.fqcRecoveryAuthorizationId ?? '',
    item.unitId ?? '',
    item.unitRate?.toString() ?? '',
  ].join('|');

  bool _isPicked(ReportablePlanLine item) =>
      _picked.any((picked) => _lineKey(picked) == _lineKey(item));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _onSearchInput(String value) {
    // Invalidate immediately, before the search debounce can fire.
    _requestGeneration++;
    setState(() {
      _keyword = value.trim();
      _items = null;
      _page = 1;
      _retryPage = 1;
      _totalPages = 1;
      _total = 0;
      _loading = true;
      _error = null;
    });
  }

  Future<void> _load({int? page, bool useCache = false}) async {
    if (!mounted) return;
    final generation = ++_requestGeneration;
    final requestedPage = page ?? _tableRows.visiblePage ?? _page;
    final keyword = _search.text.trim();
    final repository = ref.read(productionDailyReportRepositoryProvider);
    final segment = widget.executionSegmentId;
    final department = widget.departmentId;
    setState(() {
      _keyword = keyword;
      _retryPage = requestedPage;
      _error = null;
      _loading = true;
    });
    try {
      final result = await readScopedPage<ReportablePlanLine>(
        requestedPage,
        query: (repository, segment, department, keyword),
        currentQuery: () => (
          ref.read(productionDailyReportRepositoryProvider),
          widget.executionSegmentId,
          widget.departmentId,
          _search.text.trim(),
        ),
        useCache: useCache,
        fetchPage: (page) => repository.reportablePlanLines(
          executionSegmentId: segment,
          page: page,
          size: 100,
          keyword: keyword,
          departmentId: department,
        ),
      );
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _items = result.items;
        _page = result.page;
        _totalPages = result.totalPages;
        _total = result.total;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _error = productionErrorMessage(error, fallback: '加载可报工任务失败');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            UtenPanelHeader(
              title: '选择报工子任务',
              info:
                  '显示普通可报任务和 FQC 恢复任务；返工可再检报工，报废/拒收补产须重新齐套发料。\n\n'
                  '选择后会锁定计划行、销售订单行、单位口径和 FQC 恢复授权。'
                  '按实际产量报工；按已生效的允许超产比例核对，越限先办理追加计划。'
                  '保存和审核均会核对来源、重复申报及接收需求。',
              onClose: () => Navigator.of(context).pop(),
            ),
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Row(
                children: [
                  // 2026-09-11 撤掉「查询」按钮（全站同改）：防抖到点即查，回车立刻查。
                  Expanded(
                    child: UtenSearchBar(
                      controller: _search,
                      hint: '计划号 / 产品 / 订单号 / 客户',
                      onInputChanged: _onSearchInput,
                      onChanged: (_) => _load(page: 1),
                      onSubmitted: (_) => _load(page: 1),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _body(theme)),
            UtenPickerConfirmBar(
              pagination: UtenPickerPageControls(controller: _tableRows),
              selectedCount: _picked.length,
              selectedLabel: _picked.isEmpty
                  ? null
                  : _picked
                        .map(
                          (picked) =>
                              picked.executionSegmentCode ?? picked.planNo,
                        )
                        .join('、'),
              hint: _picked.isEmpty ? '共 $_total 条任务' : null,
              onConfirm: () => Navigator.of(
                context,
              ).pop(List<ReportablePlanLine>.unmodifiable(_picked)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    final items = _items ?? const <ReportablePlanLine>[];
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: MasterDataTableView<ReportablePlanLine>(
        expensiveRowMounts: false,
        showPaginationControls: false,
        tableKey:
            'features.production.widgets.reportable_plan_line_picker.ReportablePlanLineSheetState._body.1',
        virtualized: true,
        showFullscreenToggle: false,
        singleTapRows: true,
        rowsController: _tableRows,
        rowKeyOf: _lineKey,
        currentPage: _page,
        totalPages: _totalPages,
        onPageChange: (page) => _load(page: page, useCache: true),
        paginationScope: (
          widget.departmentId,
          widget.executionSegmentId,
          _keyword,
        ),
        paginationRevision: _items,
        isLoading: _loading && _items == null,
        loadingMore: _loading && _items != null,
        error: _error,
        onRetry: () => _load(page: _retryPage),
        columns: [
          MasterColumnDef(
            key: 'segmentStatus',
            label: '任务状态',
            width: 72,
            value: (item) => switch (item.executionSegmentStatus) {
              'IN_PROGRESS' when item.fqcRecoveryRequiresMaterial => '待补料/待发料',
              'IN_PROGRESS' when item.isFqcRecovery => '恢复报工',
              'IN_PROGRESS' => '普通报工',
              _ => item.executionSegmentStatus ?? '历史计划',
            },
            // 任务状态整格底色（ADR-169 逐页显式映射，按报工动作语义）：
            // 待补料/待发料=红——补产物料未齐套发料前 canReport=false，报工被
            // 硬阻断，「不能执行/被锁死不是等待」（同委外任务「等物料齐套=红」
            // 口径，轮到仓库/计划动手而非等待中的异常）/ 恢复报工=蓝——FQC
            // 恢复授权已生效、恢复产出报工流程进行中 / 普通报工=绿——就绪
            // 可动手，轮到车间报工 / 历史计划（无执行子任务）=灰；其余原始
            // 状态码保持无色纯文本。
            cellColor: (context, item) {
              if (item.executionSegmentStatus != 'IN_PROGRESS') {
                return item.executionSegmentStatus == null
                    ? utenStatusBadgeCellColor(UtenStatusBadgeType.neutral)
                    : null;
              }
              if (item.fqcRecoveryRequiresMaterial) {
                return utenStatusBadgeCellColor(UtenStatusBadgeType.danger);
              }
              return utenStatusBadgeCellColor(
                item.isFqcRecovery
                    ? UtenStatusBadgeType.info
                    : UtenStatusBadgeType.success,
              );
            },
          ),
          // 服务端分页且无 facets 端点：以下文本列关闭列头搜索，漏斗不再出空下拉
          // （顶部关键字搜索走服务端）。
          MasterColumnDef(
            key: 'planNo',
            label: '计划 / 执行子计划',
            width: 180,
            columnSearchEnabled: false,
            value: (item) => [
              item.planNo,
              item.executionSegmentCode,
              item.productNo,
            ].where((value) => value?.isNotEmpty == true).join('\n'),
          ),
          MasterColumnDef(
            key: 'sourceType',
            label: '报工类型',
            width: 120,
            value: (item) =>
                item.fqcRecoveryLabel ??
                (item.isFqcRecovery ? 'FQC恢复' : '正常生产'),
          ),
          // 2026-09-14 用户口径：产品列同时给名称+编号+颜色。选错报工对象会把
          // 完工量记到别的货上，而同名不同色/不同编号在本系统极普遍；本表没有
          // 独立的编号/颜色列。2026-09-14 用户口径（全站表格统一）：名称 / 编号 /
          // 颜色各占一列；2026-09-29 用户口径：规格不再显示在名称格副行。
          MasterColumnDef(
            key: 'goods',
            label: '产品名称',
            width: 200,
            columnSearchEnabled: false,
            value: (item) => item.goodsName ?? item.goodsCode ?? '未命名',
            cellBuilderHandlesSemantics: true,
            cellBuilder: (_, item) => UtenGoodsIdentityCell(
              name: item.goodsName,
              emptyPlaceholder: '未命名',
            ),
          ),
          MasterColumnDef(
            key: 'goodsCode',
            label: '编号',
            width: 130,
            columnSearchEnabled: false,
            value: (item) => UtenGoodsAttributeCell.text(item.goodsCode),
            cellBuilder: (_, item) => UtenGoodsAttributeCell(item.goodsCode),
          ),
          MasterColumnDef(
            key: 'colorName',
            label: '颜色',
            width: 96,
            columnSearchEnabled: false,
            value: (item) => UtenGoodsAttributeCell.text(item.colorName),
            cellBuilder: (_, item) => UtenGoodsAttributeCell(item.colorName),
          ),
          MasterColumnDef(
            // 2026-09-25 单号列统一：取件器列表就地排序（服务端分页下本地值桶
            // 不生效，列筛选关闭避免空下拉误导）。
            key: 'order',
            sortable: true,
            columnSearchEnabled: false,
            label: '销售订单/客户',
            width: 170,
            value: (item) => item.orderNo == null
                ? '内部计划 / 公共备货'
                : '${item.orderNo}\n${item.clientName ?? '—'}',
          ),
          MasterColumnDef(
            key: 'workshop',
            label: '车间',
            width: 100,
            columnSearchEnabled: false,
            value: (item) => item.workshopName ?? '未分配',
          ),
          MasterColumnDef(
            key: 'remaining',
            label: '计划/恢复余量',
            width: 90,
            type: 'number',
            value: (item) => _fmt(
              item.isFqcRecovery
                  ? item.fqcRecoveryAvailableQty
                  : item.remainingPlanQty,
            ),
          ),
          MasterColumnDef(
            key: 'maxReport',
            label: '计划内/恢复量',
            width: 90,
            type: 'number',
            value: (item) => _fmt(item.maxReportQty),
          ),
          MasterColumnDef(
            key: 'actualProduction',
            label: '报工规则',
            width: 150,
            columnSearchEnabled: false,
            value: (item) =>
                item.allowActualOverproduction && !item.isFqcRecovery
                ? '按有效超产比例核对'
                : '按当前可报量',
          ),
          MasterColumnDef(
            key: 'delivery',
            label: '交货日期',
            width: 105,
            value: (item) => item.deliveryDate ?? '未定',
          ),
        ],
        items: items,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        // 取件器单击 = selectRow()（表格自己切勾选）+ onRowTap。
        // 所以这里**只负责提示**，不再自己 _toggle，否则一次点击切两下。
        onRowTap: (item) {
          if (!item.canReport) {
            context.appWarning(
              item.blockedReason ?? '当前来源没有可报数量，请刷新后重试',
              force: true,
            );
          }
        },
        // 勾选列与点行是同一个选择集：点行切换、勾选框也切换，
        // 不可报工的行 idOf 返回 null → 勾不上（与点行的拦截同口径）。
        selectable: true,
        // 已选计数只在底部确认条（UtenPickerConfirmBar），表头不再重复胶囊。
        showSelectionSummary: false,
        idOf: (item) => item.canReport ? _lineKey(item) : null,
        selectedIds: {for (final picked in _picked) _lineKey(picked)},
        onSelectedIdsChanged: (next) => setState(() {
          _picked.removeWhere((picked) => !next.contains(_lineKey(picked)));
          for (final item in _tableRows.items) {
            if (next.contains(_lineKey(item)) && !_isPicked(item)) {
              _picked.add(item);
            }
          }
        }),
        isSelected: (item) => _isPicked(item),
        emptyMessage: '没有符合条件的可报工任务',
        rowColor: (item) {
          if (!item.canReport) {
            return theme.colorScheme.tertiaryContainer.withValues(alpha: 0.28);
          }
          final date = DateTime.tryParse(item.deliveryDate ?? '');
          if (date == null) return null;
          final days = DateUtils.dateOnly(
            date,
          ).difference(DateUtils.dateOnly(DateTime.now())).inDays;
          if (days <= 3) {
            return theme.colorScheme.errorContainer.withValues(alpha: 0.28);
          }
          return null;
        },
      ),
    );
  }

  String _fmt(double? value) {
    if (value == null) return '—';
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(2);
  }
}
