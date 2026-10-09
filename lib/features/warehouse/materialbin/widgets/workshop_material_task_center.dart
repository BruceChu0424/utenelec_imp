// 仓库任务中心 · 「车间内料仓」大类正文 (ADR-131 §8.1)。
//
// 小类: 待发料 / 待收退回 / 盘点审核 (红) / 周期盘点 (黄 = 盘点中) / 记录。
// 计数随徽章汇总一次带回 (来源键 workshopMaterial), 页面不做加法; 列表按顶栏仓库范围
// 过滤 (服务端按仓管负责的仓分发)。双击待发料 / 待收退回进入办理页。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/data_display/uten_status_cell_color.dart';
import '../../../../components/feedback/uten_context_menu.dart';
import '../../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/router/route_access_policy.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/utils/china_datetime.dart';
import '../../../../shared/badges/badge_registry.dart';
import '../../../../shared/auth/permissions.dart';
import '../../../../shared/models/paged_result.dart';
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

  /// 宿主 (仓库任务中心合并页) 的大类行。
  final Widget? externalHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    bool canOpen(String route) =>
        locationAllowedFor(permissions, superAdmin, route);
    final canIssue = canOpen(RouteName.workshopMaterialIssue);
    final canReview = canOpen(RouteName.warehouseStockCountReview);
    final canCycleCount =
        canOpen(RouteName.workshopMaterialBin) &&
        canOpen(RouteName.workshopMaterialCount);
    // ADR-149: 分段数与列表同一服务端仓库范围(任务中心选了仓 = 按所选仓汇总)。
    final reviewCount = canReview
        ? ref.watch(
            warehouseTaskEntryTodoProvider(
              BadgeEntry.warehouseStockCountReview,
            ),
          )
        : null;
    final warehouseScope = ref.watch(warehouseTaskScopeProvider);
    final pendingIssue = ref.watch(
      warehouseTaskFactOrNullProvider(BadgeFact.workshopMaterialPendingIssue),
    );
    final pendingReturn = ref.watch(
      warehouseTaskFactOrNullProvider(BadgeFact.workshopMaterialPendingReturn),
    );
    final counting = ref.watch(
      warehouseTaskFactOrNullProvider(BadgeFact.workshopMaterialCounting),
    );
    return WarehouseTaskCenterScaffold(
      location: RouteName.warehouseTasks,
      title: l10n.workshopMaterialGroup,
      searchHint: '搜索单号 / 车间 / 料',
      initialSegment: initialSection,
      segments: [
        if (canIssue)
          WarehouseTaskSegmentSpec(
            value: 'pendingIssue',
            label: l10n.wmPendingIssue,
            count: pendingIssue,
          ),
        if (canIssue)
          WarehouseTaskSegmentSpec(
            value: 'pendingReturn',
            label: l10n.wmPendingReturn,
            count: pendingReturn,
          ),
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
        if (canIssue)
          WarehouseTaskSegmentSpec(value: 'history', label: l10n.wmHistory),
      ],
      embedded: true,
      externalKeyword: externalKeyword,
      externalRefreshTick: externalRefreshTick,
      externalHeader: externalHeader,
      onResume: () => invalidateWarehouseTaskCounts(ref),
      trailingBuilder: !canIssue
          ? null
          : (_) => UtenButton(
              key: const Key('wm-task-direct-issue'),
              icon: Icons.local_shipping_outlined,
              onPressed: () async {
                await context.push(RoutePath.workshopMaterialDirectIssue());
                if (context.mounted) invalidateWarehouseTaskCounts(ref);
              },
              child: Text(l10n.wmDirectIssue),
            ),
      bodyBuilder: (segment, keyword, refreshTick, headerPrefix) =>
          switch (segment) {
            'pendingIssue' => WmRequisitionSegment(
              key: const ValueKey('wm-seg-pending-issue'),
              status: 'PENDING',
              kind: 'ISSUE',
              keyword: keyword,
              refreshTick: refreshTick,
              header: headerPrefix,
            ),
            'pendingReturn' => WmRequisitionSegment(
              key: const ValueKey('wm-seg-pending-return'),
              status: 'PENDING',
              kind: 'RETURN',
              keyword: keyword,
              refreshTick: refreshTick,
              header: headerPrefix,
            ),
            'count' => StockCountReviewPage(
              key: const ValueKey('wm-stock-count-review'),
              reviewRoute: 'WAREHOUSE',
              embedded: true,
              externalHeader: headerPrefix,
              externalRefreshTick: refreshTick,
              warehouseScope: warehouseScope,
              keyword: keyword,
              onChanged: () => invalidateWarehouseTaskCounts(ref),
            ),
            'periodCount' => WmBinStatusSegment(
              refreshTick: refreshTick,
              header: headerPrefix,
            ),
            _ => WmRequisitionSegment(
              key: const ValueKey('wm-seg-history'),
              keyword: keyword,
              refreshTick: refreshTick,
              header: headerPrefix,
            ),
          },
    );
  }
}

/// 领料 / 退回单列表 (待发料、待收退回、记录共用)。
class WmRequisitionSegment extends ConsumerStatefulWidget {
  const WmRequisitionSegment({
    super.key,
    this.status,
    this.kind,
    required this.keyword,
    required this.refreshTick,
    required this.header,
  });

  final String? status;
  final String? kind;
  final String keyword;
  final int refreshTick;
  final Widget header;

  @override
  ConsumerState<WmRequisitionSegment> createState() =>
      _WmRequisitionSegmentState();
}

class _WmRequisitionSegmentState extends ConsumerState<WmRequisitionSegment> {
  PagedResult<WmRequisition>? _result;
  bool _loading = false;
  String? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  @override
  void didUpdateWidget(covariant WmRequisitionSegment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword ||
        oldWidget.refreshTick != widget.refreshTick) {
      _load(1);
    }
  }

  Future<void> _load(int page) async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(workshopMaterialRepositoryProvider)
          .requisitions(
            status: widget.status,
            kind: widget.kind,
            keyword: widget.keyword,
            page: page,
            scope: WarehouseListScope.of(context).queryParameters,
          );
      if (!mounted || seq != _seq) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted && seq == _seq) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted && seq == _seq) {
        setState(() {
          _loading = false;
          _error = '加载失败, 请重试';
        });
      }
    }
  }

  Future<void> _open(WmRequisition r) async {
    await context.push(RoutePath.workshopMaterialIssueForRequisition(r.id));
    if (mounted) {
      invalidateWarehouseTaskCounts(ref);
      _load(_result?.page ?? 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final items = _result?.items ?? const <WmRequisition>[];
    final pending = widget.status == 'PENDING';
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          widget.header,
          const SizedBox(height: UtenSpacing.s12),
        ],
      ),
      body: MasterDataTableView<WmRequisition>(
        tableKey:
            'features.warehouse.materialbin.widgets.workshop_material_task_center.WmRequisitionSegmentState.build.1',
        key: Key(
          'wm-requisitions-${widget.kind ?? 'all'}-${widget.status ?? 'all'}',
        ),
        primary: true,
        columns: [
          MasterColumnDef(
            key: 'status',
            label: '状态',
            width: 72,
            value: (r) => wmRequisitionStatusLabel(r.status),
            // 任务分段（待发料/待收退回）里 PENDING=轮到仓库动手 → 绿；
            // 记录分段混排 PENDING/DONE/CANCELLED，沿用黄/绿/灰互区分。
            cellColor: (context, r) => utenStatusBadgeCellColor(
              wmRequisitionStatusBadgeType(r.status, taskView: pending),
            ),
          ),
          MasterColumnDef(
            key: 'requestNo',
            label: '单号',
            width: 160,
            value: (r) => r.requestNo,
          ),
          MasterColumnDef(
            key: 'workshop',
            label: '车间',
            width: 130,
            value: (r) => r.workshopName,
          ),
          if (widget.kind == null)
            MasterColumnDef(
              key: 'kind',
              label: '类型',
              width: 90,
              value: (r) => wmRequisitionKindLabel(l10n, r.kind),
            ),
          MasterColumnDef(
            key: 'material',
            label: '料',
            width: 220,
            value: (r) => r.materialSummary,
          ),
          MasterColumnDef(
            key: 'qty',
            label: l10n.wmKg,
            width: 100,
            type: 'number',
            value: (r) => wmQty(r.totalQty),
          ),
          MasterColumnDef(
            key: 'requestedBy',
            label: '申请人',
            width: 100,
            value: (r) => r.requestedByName,
          ),
          MasterColumnDef(
            key: 'requestedAt',
            label: '申请时间',
            width: 150,
            value: (r) => ChinaDateTime.formatIsoInstant(r.requestedAt),
          ),
          if (!pending) ...[
            MasterColumnDef(
              key: 'origin',
              label: '来源',
              width: 120,
              value: (r) => wmRequisitionOriginLabel(r.origin),
            ),
            MasterColumnDef(
              key: 'receiver',
              label: l10n.wmReceiver,
              width: 100,
              value: (r) => r.receiverName,
            ),
            MasterColumnDef(
              key: 'doneBy',
              label: '经办',
              width: 100,
              value: (r) => r.doneByName,
            ),
            MasterColumnDef(
              key: 'doneAt',
              label: '完成时间',
              width: 150,
              value: (r) => ChinaDateTime.formatIsoInstant(r.doneAt),
            ),
          ],
        ],
        items: items,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        rowKeyOf: (r) => r.id,
        onRowTap: _open,
        rowMenuBuilder: (r) => [
          UtenMenuItem(
            label: r.isPending && r.can(WmAction.fulfil)
                ? (r.isReturn ? '收退回' : '按申请发料')
                : '查看',
            icon: r.isReturn
                ? Icons.move_to_inbox_outlined
                : Icons.local_shipping_outlined,
            onTap: () => _open(r),
          ),
        ],
        isLoading: _loading && _result == null,
        loadingMore: _loading && _result != null,
        error: _result == null ? _error : null,
        onRetry: () => _load(_result?.page ?? 1),
        currentPage: _result?.page ?? 1,
        totalPages: _result?.totalPages ?? 1,
        paginationScope: (
          widget.status,
          widget.kind,
          widget.keyword,
          WarehouseListScope.of(context),
        ),
        onPageChange: _load,
        emptyMessage: pending
            ? (widget.kind == 'RETURN' ? '没有待收的退回' : '没有待发的领料申请')
            : '还没有记录',
      ),
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
  });

  final int refreshTick;
  final Widget header;

  @override
  ConsumerState<WmBinStatusSegment> createState() => _WmBinStatusSegmentState();
}

class _WmBinStatusSegmentState extends ConsumerState<WmBinStatusSegment> {
  List<_BinStatusRow>? _rows;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant WmBinStatusSegment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshTick != widget.refreshTick) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(workshopMaterialRepositoryProvider);
      final settings = [
        for (final s in await repo.settings())
          if (s.periodicEnabled && s.binWarehouseId != null) s,
      ];
      final periods = await Future.wait([
        for (final s in settings) repo.periods(s.binWarehouseId!),
      ]);
      if (!mounted) return;
      final rows = <_BinStatusRow>[];
      for (var i = 0; i < settings.length; i++) {
        final sorted = [...periods[i]]
          ..sort((a, b) => a.periodNo.compareTo(b.periodNo));
        WmPeriod? target;
        for (final p in sorted) {
          if (p.status == WmPeriodStatus.counting ||
              p.status == WmPeriodStatus.counted) {
            target = p;
            break;
          }
        }
        target ??= sorted
            .where((p) => p.status == WmPeriodStatus.open)
            .firstOrNull;
        rows.add(_BinStatusRow(setting: settings[i], period: target));
      }
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
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
    final rows = _rows ?? const <_BinStatusRow>[];
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          widget.header,
          const SizedBox(height: UtenSpacing.s12),
        ],
      ),
      body: MasterDataTableView<_BinStatusRow>(
        tableKey:
            'features.warehouse.materialbin.widgets.workshop_material_task_center.WmBinStatusSegmentState.build.1',
        key: const Key('wm-bin-status-table'),
        primary: true,
        columns: [
          MasterColumnDef(
            key: 'status',
            label: '盘点',
            width: 72,
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
        emptyMessage: '还没有开启整批领料的车间',
      ),
    );
  }
}
