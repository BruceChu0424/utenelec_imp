import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../components/data_display/uten_status_cell_color.dart';
import '../../../../components/feedback/uten_context_menu.dart';
import '../../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../../components/layout/uten_refresh_scope.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/router/route_access_policy.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../shared/badges/badge_registry.dart';
import '../../../../shared/auth/permissions.dart';
import '../../../../shared/warehouse/warehouse_task_badges.dart';
import '../../../../shared/warehouse/warehouse_task_scope.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../../../stock/counts/pages/stock_count_review_page.dart';
import '../../providers/warehouse_count_refresh.dart';
import '../../widgets/warehouse_task_center_scaffold.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import 'workshop_material_labels.dart';

class WorkshopMaterialTaskCenter extends ConsumerWidget {
  const WorkshopMaterialTaskCenter({
    super.key,
    this.externalKeyword,
    this.externalRefreshTick,
    this.externalHeader,
    this.initialSection,
  });

  final String? externalKeyword;
  final int? externalRefreshTick;
  final String? initialSection;
  final Widget? externalHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    bool canOpen(String route) =>
        locationAllowedFor(permissions, superAdmin, route);
    final canReview = canOpen(RouteName.warehouseStockCountReview);
    final canCycleCount =
        canOpen(RouteName.workshopMaterialBin) &&
        canOpen(RouteName.workshopMaterialCount);
    final reviewCount = canReview
        ? ref.watch(
            warehouseTaskEntryTodoProvider(
              BadgeEntry.warehouseStockCountReview,
            ),
          )
        : null;
    final warehouseScope = ref.watch(warehouseTaskScopeProvider);
    final counting = ref.watch(
      warehouseTaskFactOrNullProvider(BadgeFact.workshopMaterialCounting),
    );
    if (!canReview && !canCycleCount) {
      return const Center(child: Text('暂无已授权的内料仓审核任务'));
    }
    return WarehouseTaskCenterScaffold(
      location: RouteName.warehouseTasks,
      title: '车间内料仓',
      searchHint: '搜索盘点单号 / 车间 / 货品',
      initialSegment: initialSection,
      segments: [
        if (canReview)
          WarehouseTaskSegmentSpec(
            value: 'count',
            label: '盘点审核',
            count: reviewCount,
          ),
        if (canCycleCount)
          WarehouseTaskSegmentSpec(
            value: 'periodCount',
            label: '周期盘点',
            inProgressCount: counting,
          ),
        if (canReview)
          const WarehouseTaskSegmentSpec(value: 'history', label: '审核记录'),
      ],
      embedded: true,
      externalKeyword: externalKeyword,
      externalRefreshTick: externalRefreshTick,
      externalHeader: externalHeader,
      onResume: () => invalidateWarehouseTaskCounts(ref),
      bodyBuilder: (segment, keyword, refreshTick, header) => switch (segment) {
        'periodCount' => WmBinStatusSegment(
          refreshTick: refreshTick,
          header: header,
          keyword: keyword,
        ),
        _ => StockCountReviewPage(
          key: ValueKey(('wm-stock-count-review', segment)),
          reviewRoute: 'WAREHOUSE',
          initialStatus: segment == 'history' ? 'HISTORY' : 'PENDING',
          embedded: true,
          externalHeader: header,
          externalRefreshTick: refreshTick,
          warehouseScope: warehouseScope,
          keyword: keyword,
          onChanged: () => invalidateWarehouseTaskCounts(ref),
        ),
      },
    );
  }
}

/// 一个车间内料仓的盘点 / 结算状态行。
class _BinStatusRow {
  const _BinStatusRow({required this.setting, this.period});

  final WmSetting setting;

  /// 最早一期"盘点中 / 已盘点未结算"; 没有时为开着的那一期。
  final WmPeriod? period;
}

/// 盘点小类: 各车间内料仓当前在盘哪一期、结算到哪。
class WmBinStatusSegment extends ConsumerStatefulWidget {
  const WmBinStatusSegment({
    super.key,
    required this.refreshTick,
    required this.header,
    this.keyword = '',
  });

  final int refreshTick;
  final Widget header;
  final String keyword;

  @override
  ConsumerState<WmBinStatusSegment> createState() => _WmBinStatusSegmentState();
}

class _WmBinStatusSegmentState extends ConsumerState<WmBinStatusSegment>
    with UtenRefreshParticipant<WmBinStatusSegment> {
  List<_BinStatusRow>? _rows;
  bool _loading = false;
  String? _error;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => trackRefresh(_load()));
  }

  @override
  void didUpdateWidget(covariant WmBinStatusSegment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshTick != widget.refreshTick) trackRefresh(_load());
  }

  Future<void> _load() async {
    final revision = ++_revision;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(workshopMaterialRepositoryProvider);
      final settings = [
        for (final s in await repo.taskStatus(
          scope: WarehouseListScope.of(context).queryParameters,
        ))
          if (s.periodicEnabled && s.binWarehouseId != null) s,
      ];
      if (!mounted || revision != _revision) return;
      final rows = [
        for (final setting in settings)
          _BinStatusRow(
            setting: setting,
            period: setting.pendingPeriod ?? setting.currentPeriod,
          ),
      ];
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted && revision == _revision) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted && revision == _revision) {
        setState(() {
          _loading = false;
          _error = '加载失败, 请重试';
        });
      }
    }
  }

  Future<void> _open(_BinStatusRow row) async {
    final period = row.period;
    if (period != null && period.status != WmPeriodStatus.open) {
      await context.push(RoutePath.workshopMaterialCount(period.id));
    } else {
      await context.push(
        RoutePath.workshopMaterialBin(
          workshopId: row.setting.workshopDepartmentId,
        ),
      );
    }
    if (mounted) {
      invalidateWarehouseTaskCounts(ref);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyword = widget.keyword.trim().toLowerCase();
    final rows = [
      for (final row in _rows ?? const <_BinStatusRow>[])
        if (keyword.isEmpty ||
            [
              row.setting.workshopName,
              row.setting.binWarehouseName ?? '',
              if (row.period != null) wmPeriodLabel(row.period!),
            ].join(' ').toLowerCase().contains(keyword))
          row,
    ];
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          widget.header,
          const SizedBox(height: UtenSpacing.s8),
        ],
      ),
      body: MasterDataTableView<_BinStatusRow>(
        tableKey:
            'features.warehouse.materialbin.widgets.workshop_material_task_center.WmBinStatusSegmentState.build.1',
        key: const Key('wm-bin-status-table'),
        primary: true,
        requiredLeadingColumnKeys: const ['status', 'close'],
        columns: [
          MasterColumnDef(
            key: 'status',
            label: '盘点',
            width: 72,
            filterFromRows: true,
            value: (r) =>
                r.period == null ? null : wmPeriodStatusLabel(r.period!.status),
            // 2026-10-01 口径「不同状态不同颜色」：开着绿 / 盘点中蓝 /
            // 已盘点待结算琥珀 / 已结算灰。
            cellColor: (context, r) => r.period == null
                ? null
                : utenStatusBadgeCellColor(
                    wmPeriodStatusBadgeType(r.period!.status),
                  ),
          ),
          MasterColumnDef(
            key: 'close',
            label: '结算',
            width: 72,
            filterFromRows: true,
            value: (r) => r.period == null
                ? null
                : wmCloseStateLabel(r.period!.closeState),
            // 自动结算中蓝 / 差资料红（硬阻断）/ 结算没成功红 / 已撤销灰；
            // 开着不上色。
            cellColor: (context, r) {
              final type = r.period == null
                  ? null
                  : wmCloseStateBadgeType(r.period!.closeState);
              return type == null ? null : utenStatusBadgeCellColor(type);
            },
          ),
          MasterColumnDef(
            key: 'workshop',
            label: '车间',
            width: 140,
            value: (r) => r.setting.workshopName,
          ),
          MasterColumnDef(
            key: 'bin',
            label: '内料仓',
            width: 180,
            value: (r) => r.setting.binWarehouseName,
          ),
          MasterColumnDef(
            key: 'period',
            label: '期间',
            width: 240,
            value: (r) => r.period == null ? null : wmPeriodLabel(r.period!),
          ),
        ],
        items: rows,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        rowKeyOf: (r) => r.setting.workshopDepartmentId,
        onRowTap: _open,
        rowMenuBuilder: (r) => [
          UtenMenuItem(
            label: r.period != null && r.period!.status != WmPeriodStatus.open
                ? '打开盘点页'
                : '打开车间内料仓',
            icon: Icons.fact_check_outlined,
            onTap: () => _open(r),
          ),
        ],
        isLoading: _loading && _rows == null,
        loadingMore: _loading && _rows != null,
        error: _rows == null ? _error : null,
        onRetry: _load,
        emptyMessage: '当前仓库范围没有已开启整批领料的车间',
      ),
    );
  }
}
