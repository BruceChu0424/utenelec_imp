// 预计到货工作台（可嵌入）：与财务「订货审批任务中心」同款表格工作台——列表只放
// 单据级概要（单号/供应商/数量/预计到货日/步骤），双击行（或右键「查看到货详情」）
// 弹详情看待收明细并就地执行登记/送检，不在列表里铺明细。
//
// 2026-09-01 起「入库任务中心」采购入库/委外入库分段内嵌本组件（fixedOrderType
// 固定来源、embedded=true 不渲染自己的类型分段与搜索框——关键字由任务中心页级
// 工具条统一下发）；独立路由 /warehouse/inbound/expectations 由对应页面以
// embedded=false 包一层继续承接（委外模块卡片深链依赖它）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../providers/procurement_inbound_count_providers.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/procurement_inbound_repository.dart';
import '../repositories/procurement_inspection_repository.dart';

class WarehouseInboundExpectationsView extends ConsumerStatefulWidget {
  const WarehouseInboundExpectationsView({
    super.key,
    this.fixedOrderType,
    this.keyword = '',
    this.refreshTick = 0,
    this.embedded = false,
  });

  /// 任务中心分段固定的订货来源（采购入库=PURCHASE / 委外入库=SUBCONTRACT）；
  /// null = 独立页模式（自带类型分段）。
  final ProcurementInboundOrderType? fixedOrderType;

  /// 任务中心页级搜索关键字（embedded 模式生效）。
  final String keyword;

  /// 父页面「返回即刷新」信号。
  final int refreshTick;

  /// true = 嵌在任务中心分段内（无类型分段与搜索框，仅提示行 + 表格）。
  final bool embedded;

  @override
  ConsumerState<WarehouseInboundExpectationsView> createState() =>
      _WarehouseInboundExpectationsViewState();
}

class _WarehouseInboundExpectationsViewState
    extends ConsumerState<WarehouseInboundExpectationsView> {
  PagedResult<InboundExpectation>? _result;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;

  /// 类型筛选（表头筛选与类型分段按钮共用这一个口径）：null = 全部待到货。
  /// 进页面不预选（不选=不过滤），点分段后才算选中；任务中心嵌入时由
  /// [WarehouseInboundExpectationsView.fixedOrderType] 固定。
  ProcurementInboundOrderType? _orderType;
  bool _typeSelected = false;

  /// 按类型计数（后端全量口径）；null = 尚未返回，分段按钮显示 '—'。
  Map<String, int>? _typeCounts;

  /// 搜索关键字（订货单号/供应商/货品编码或名称），UtenSearchBar 300ms 防抖后回写。
  String _keyword = '';

  /// 已送检待品质放行的收货单张数（口径提示用；null = 尚未返回或无查看权限）。
  int? _inspectionPendingCount;

  /// 品质待检计数仅对有查看权限者拉取（服务端接口独立鉴权兜底）。
  bool get _canViewInspection =>
      ref.read(isSuperAdminProvider) ||
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.procurementInspectionView);

  @override
  void initState() {
    super.initState();
    _orderType = widget.fixedOrderType;
    _typeSelected = widget.fixedOrderType != null;
    _keyword = widget.keyword;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  @override
  void didUpdateWidget(WarehouseInboundExpectationsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword ||
        oldWidget.refreshTick != widget.refreshTick) {
      _keyword = widget.keyword;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
    }
  }

  /// 当前筛选口径的提示文案（与财务审批任务中心同款：说明放工具条下方整行提示）。
  String get _scopeHint {
    final base = switch (_orderType) {
      ProcurementInboundOrderType.purchase => '只显示财务已批准、可准备收货的采购订货单。',
      ProcurementInboundOrderType.subcontract => '只显示目标件已经真实委外出仓、可能回厂的委外订货单。',
      _ => '采购在财务批准后显示；委外必须先完成目标件真实出仓，才进入预计到货。',
    };
    if (_orderType != null) return base;
    final pending = _inspectionPendingCount;
    if (pending == null) {
      return '$base已送检任务移交品质部；检查进度与结果请在「品质部检查结果」页查看。';
    }
    return '$base另有 $pending 张已送检等待品质结果；'
        '检查进度与结果请在「品质部检查结果」页查看。';
  }

  void _selectType(ProcurementInboundOrderType? type) {
    if (_orderType == type && _typeSelected) return;
    setState(() {
      _orderType = type;
      _typeSelected = true;
    });
    _load(1);
  }

  void _applyKeyword(String value) {
    final normalized = value.trim();
    if (_keyword == normalized) return;
    setState(() => _keyword = normalized);
    _load(1);
  }

  int? _typeCount(ProcurementInboundOrderType type) {
    final counts = _typeCounts;
    if (counts == null) return null;
    return switch (type) {
      ProcurementInboundOrderType.purchase => counts['PURCHASE'] ?? 0,
      ProcurementInboundOrderType.subcontract => counts['SUBCONTRACT'] ?? 0,
      _ => 0,
    };
  }

  Future<void> _load(int page) async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(procurementInboundRepositoryProvider);
      final result = await repo.expectations(
        page: page,
        orderType: _orderType,
        keyword: _keyword.isEmpty ? null : _keyword,
      );
      // 类型计数失败不阻断列表（分段按钮降级为 '—'）。
      repo
          .expectationTypeCounts()
          .then((counts) {
            if (mounted) setState(() => _typeCounts = counts);
          })
          .catchError((_) {});
      // 已送检待品质计数同理：失败仅不显示该句提示。
      if (_canViewInspection) {
        ref
            .read(procurementInspectionRepositoryProvider)
            .pendingCount()
            .then((count) {
              if (mounted) {
                setState(() => _inspectionPendingCount = count);
              }
            })
            .catchError((_) {});
      }
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
      });
      ref.invalidate(warehouseInboundExpectationCountProvider);
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = '预计到货加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  /// 双击行 / 右键「查看到货详情」：弹详情看单据概要与待收明细，就地执行登记/送检。
  Future<void> _openDetail(InboundExpectation expectation) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => _ExpectationDetailDialog(
        expectation: expectation,
        // 详情里点动作先关弹窗再走原链路（登记页 push / 完成送检请求），返回后
        // 任务中心就地刷新（与旧卡片按钮同一路径）。
        onCreateReceipt: () {
          Navigator.of(dialogContext).pop();
          _createReceipt(expectation);
        },
        onCompleteRegistration: () {
          Navigator.of(dialogContext).pop();
          _completeRegistration(expectation);
        },
        onOpenExceptions: () {
          Navigator.of(dialogContext).pop();
          context.go(RouteName.warehouseArrivalExceptions);
        },
      ),
    );
  }

  Future<void> _createReceipt(InboundExpectation expectation) async {
    final prefill = expectation.toReceiptPrefill();
    final route = expectation.orderType.receiptCreateRoute;
    if (prefill == null || route == null) {
      context.appWarning('该预计到货任务暂不能登记，请刷新后重试');
      return;
    }
    // 登记页「登记并送检」一步完成（保存+审核同事务）：返回结果即终态——
    // 正常已转品质部待检，超量已隔离待财务。回本页就地刷新一次并提示下一步，
    // 不再跳采购/委外收货单详情页（仓库流程全程留在仓储模块，也消除闪跳）。
    final registration = await context.push<WarehouseArrivalRegistration>(
      route,
      extra: prefill,
    );
    if (registration == null || !mounted) return;
    await _load(_result?.page ?? 1);
    if (mounted) _announceRegistration(registration);
  }

  /// 断点恢复：草稿收货单一键「继续送检」（服务端按订货单修复币族后走同一审核
  /// 链路）——中途退出的仓库人员在详情弹窗里直接完成停止的步骤，不进采购/委外单据页。
  Future<void> _completeRegistration(InboundExpectation expectation) async {
    if (expectation.draftReceiptIds.isEmpty) return;
    final confirmed = await showUtenReviewerConfirmDialog(
      context,
      title: '继续送检',
      actionLabel: '送检',
      confirmLabel: '确认送检',
      message:
          '将把已登记的到货数量送品质部待检(IQC)：检验合格后转仓库待入库任务，'
          '仓库确认实物与库位后库存才增加；'
          '实到超过财务批准量时系统自动隔离并通知财务审核组，不会入库、不会生成应付。'
          '单价按订货单自动带入，无需填写。',
    );
    if (confirmed != true) return;
    try {
      final registration = await ref
          .read(procurementInboundRepositoryProvider)
          .completeArrival(expectation.draftReceiptIds.first);
      if (!mounted) return;
      await _load(_result?.page ?? 1);
      if (mounted) _announceRegistration(registration);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('送检失败，请稍后重试');
    }
  }

  /// 到货登记/送检结果的下一步提示（正常 → 品质检验 → 仓库确认入库；超量 → 财务定案）。
  /// 成功即失效全部仓库任务计数：分段徽章/hub 卡/工作台角标立即联动。
  void _announceRegistration(WarehouseArrivalRegistration registration) {
    invalidateWarehouseTaskCounts(ref);
    switch (registration.outcome) {
      case WarehouseArrivalRegistrationOutcome.submittedForInspection:
        context.appSuccess(
          '到货已送检(${registration.receiptBillNo ?? ''})：'
          '检查进度与结果请在「品质部检查结果」页查看；'
          '合格后在同一页核对实物与库位确认入库',
        );
      case WarehouseArrivalRegistrationOutcome.excessQuarantined:
        context.appWarning(
          '实到超过财务批准量，已隔离未入库(${registration.receiptBillNo ?? ''})：'
          '待财务在到货异常审批定案后，可在「到货异常任务中心」一键入库',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return _loading && result == null
        ? const UtenSkeletonList()
        : _error != null && result == null
        ? UtenEmpty.error(
            message: _error,
            actionLabel: '重新加载',
            onAction: () => _load(1),
          )
        : _buildList(result);
  }

  Widget _buildList(PagedResult<InboundExpectation>? value) {
    final result =
        value ??
        const PagedResult<InboundExpectation>(
          items: [],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 1,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.embedded) ..._buildToolbar(result),
        if (widget.embedded) _scopeHintRow(),
        if (_error != null) ...[
          const SizedBox(height: UtenSpacing.s12),
          _InlineError(message: _error!, onRetry: () => _load(result.page)),
        ],
        const SizedBox(height: UtenSpacing.s12),
        Expanded(
          child: MasterDataTableView<InboundExpectation>(
            key: const Key('inbound-expectation-task-table'),
            columns: _columns,
            items: result.items,
            facets: {
              'orderType': [
                MasterFacetBucket(
                  value: 'PURCHASE',
                  count: _typeCount(ProcurementInboundOrderType.purchase) ?? 0,
                  label: '采购订货',
                ),
                MasterFacetBucket(
                  value: 'SUBCONTRACT',
                  count:
                      _typeCount(ProcurementInboundOrderType.subcontract) ?? 0,
                  label: '委外订货',
                ),
              ],
            },
            nullCounts: const {},
            filters: {'orderType': _orderType?.name.toUpperCase()},
            onFilterChanged: (key, value) {
              if (key != 'orderType' || widget.fixedOrderType != null) return;
              _selectType(switch (value) {
                'PURCHASE' => ProcurementInboundOrderType.purchase,
                'SUBCONTRACT' => ProcurementInboundOrderType.subcontract,
                _ => null,
              });
            },
            onRowTap: _openDetail,
            rowMenuBuilder: (expectation) => [
              UtenMenuItem(
                label: '查看到货详情',
                icon: Icons.open_in_new_rounded,
                onTap: () => _openDetail(expectation),
              ),
              if (expectation.arrivalStep == InboundArrivalStep.readyToRegister)
                UtenMenuItem(
                  label: '登记实际到货',
                  icon: Icons.inventory_2_outlined,
                  onTap: () => _createReceipt(expectation),
                ),
              if (expectation.arrivalStep ==
                  InboundArrivalStep.draftPendingInspection)
                UtenMenuItem(
                  label: '继续送检',
                  icon: Icons.fact_check_outlined,
                  onTap: () => _completeRegistration(expectation),
                ),
              if (expectation.arrivalStep ==
                  InboundArrivalStep.excessPendingFinance)
                UtenMenuItem(
                  label: '前往到货异常任务中心',
                  icon: Icons.account_balance_outlined,
                  onTap: () => context.go(RouteName.warehouseArrivalExceptions),
                ),
            ],
            isLoading: _loading,
            loadingMore: _loading && _result != null,
            error: result.items.isEmpty ? _error : null,
            onRetry: () => _load(result.page),
            emptyMessage: _keyword.isNotEmpty || _orderType != null
                ? '没有匹配的预计到货'
                : '目前没有预计到货',
            currentPage: result.page,
            totalPages: result.totalPages,
            onPageChange: _load,
          ),
        ),
      ],
    );
  }

  List<Widget> _buildToolbar(PagedResult<InboundExpectation> result) {
    final theme = Theme.of(context);
    return [
      Semantics(
        header: true,
        label: '共有 ${result.total} 张待到货订货单',
        // 全平台统一筛选工具条：分段(红圆计数徽章，计数取后端全量口径) + 胶囊搜索框。
        child: UtenFilterToolbar<String>(
          segmentsKey: const Key('inbound-expectation-type-segments'),
          searchKey: const Key('inbound-expectation-search'),
          segments: [
            // 「全部待到货」不挂徽章——徽章只挂各来源分段的待到货数量。
            const UtenFilterSegment(value: 'all', label: '全部待到货'),
            UtenFilterSegment(
              value: 'purchase',
              label: '采购订货',
              count: _typeCount(ProcurementInboundOrderType.purchase),
            ),
            UtenFilterSegment(
              value: 'subcontract',
              label: '委外订货',
              count: _typeCount(ProcurementInboundOrderType.subcontract),
            ),
          ],
          selected: _typeSelected
              ? {
                  _orderType == null
                      ? 'all'
                      : _orderType == ProcurementInboundOrderType.purchase
                      ? 'purchase'
                      : 'subcontract',
                }
              : const {},
          onSelectionChanged: (value) => _selectType(switch (value) {
            'purchase' => ProcurementInboundOrderType.purchase,
            'subcontract' => ProcurementInboundOrderType.subcontract,
            _ => null,
          }),
          searchHint: '搜索订货单号 / 供应商 / 货品',
          initialSearchValue: _keyword,
          onSearchInputChanged: (_) => _requestVersion++,
          onSearchChanged: _applyKeyword,
          trailing: Text(
            '共 ${result.total} 张 · 单击选中，双击详情',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
      const SizedBox(height: UtenSpacing.s8),
      _scopeHintRow(),
    ];
  }

  Widget _scopeHintRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline_rounded,
          size: 18,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Text(_scopeHint, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }

  List<MasterColumnDef<InboundExpectation>> get _columns => [
    MasterColumnDef(
      key: 'orderType',
      label: '订货类型',
      width: 110,
      value: (expectation) => expectation.orderType.label,
    ),
    MasterColumnDef(
      key: 'billNo',
      label: '订货单号',
      width: 170,
      value: (expectation) => expectation.billNo,
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '供应商 / 委外商',
      width: 210,
      value: (expectation) => expectation.supplierName ?? '—',
    ),
    MasterColumnDef(
      key: 'expectedDate',
      label: '预计到货日',
      width: 120,
      type: 'date',
      value: (expectation) => expectation.expectedDate ?? '—',
    ),
    MasterColumnDef(
      key: 'itemCount',
      label: '明细行数',
      width: 100,
      type: 'number',
      value: (expectation) => expectation.items.length.toString(),
    ),
    MasterColumnDef(
      key: 'step',
      label: '到货步骤',
      width: 170,
      value: (expectation) => _stepColumnLabel(expectation),
      cellColor: (context, expectation) {
        if (expectation.arrivalStep != InboundArrivalStep.awaitingQuality) {
          return null;
        }
        return Theme.of(context).brightness == Brightness.dark
            ? UtenColors.warning.withValues(alpha: 0.18)
            : UtenColors.warningBg;
      },
    ),
    MasterColumnDef(
      key: 'ownerEmployeeName',
      label: '负责人',
      width: 140,
      value: (expectation) => expectation.ownerEmployeeName ?? '—',
    ),
  ];
}

/// 到货步骤列文案：列表只放单据级概要，数量化的进度（超量笔数等）随步骤带出。
String _stepColumnLabel(InboundExpectation expectation) {
  final step = expectation.arrivalStep;
  return switch (step) {
    InboundArrivalStep.readyToRegister => '待登记到货',
    InboundArrivalStep.draftPendingInspection => '已登记 · 待送检',
    InboundArrivalStep.excessPendingFinance =>
      expectation.openArrivalExceptions > 0
          ? '超量待财务(${expectation.openArrivalExceptions})'
          : '超量待财务',
    InboundArrivalStep.awaitingQuality => '已送检 · 结果见「品质部检查结果」',
    InboundArrivalStep.blocked => '暂不能登记',
  };
}

/// 预计到货详情弹窗：单据概要 + 待收明细 + 按当前步骤收口的动作按钮
/// （待登记→登记实际到货；已登记→继续送检；超量→去异常中心；已送检→只读）。
class _ExpectationDetailDialog extends StatelessWidget {
  const _ExpectationDetailDialog({
    required this.expectation,
    required this.onCreateReceipt,
    required this.onCompleteRegistration,
    required this.onOpenExceptions,
  });

  final InboundExpectation expectation;
  final VoidCallback onCreateReceipt;
  final VoidCallback onCompleteRegistration;
  final VoidCallback onOpenExceptions;

  InboundArrivalStep get _step => expectation.arrivalStep;

  String _stepLabel(InboundArrivalStep step) => switch (step) {
    InboundArrivalStep.readyToRegister => '待登记到货',
    InboundArrivalStep.draftPendingInspection => '已登记 · 待送检',
    InboundArrivalStep.excessPendingFinance => '超量 · 待财务审批',
    InboundArrivalStep.awaitingQuality => '已送检 · 结果见「品质部检查结果」',
    InboundArrivalStep.blocked => '暂不能登记',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final receivableItems = expectation.items.where((item) => item.canReceive);
    return AlertDialog(
      title: Row(
        children: [
          UtenStatusBadge(
            label: '${expectation.orderType.label}到货',
            type: expectation.orderType == ProcurementInboundOrderType.purchase
                ? UtenStatusBadgeType.info
                : UtenStatusBadgeType.accent,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              expectation.billNo,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 流水线步骤徽章：一眼看出这个到货任务停在哪一步。
              Row(
                children: [
                  Icon(
                    switch (_step) {
                      InboundArrivalStep.readyToRegister =>
                        Icons.inventory_2_outlined,
                      InboundArrivalStep.draftPendingInspection =>
                        Icons.pending_actions_outlined,
                      InboundArrivalStep.excessPendingFinance =>
                        Icons.account_balance_outlined,
                      InboundArrivalStep.awaitingQuality =>
                        Icons.fact_check_outlined,
                      InboundArrivalStep.blocked => Icons.block_outlined,
                    },
                    size: 16,
                    color: _step == InboundArrivalStep.excessPendingFinance
                        ? theme.colorScheme.error
                        : _step == InboundArrivalStep.awaitingQuality
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: UtenSpacing.s4),
                  Text(
                    _stepLabel(_step),
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: _step == InboundArrivalStep.excessPendingFinance
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              _InfoLine(
                icon: Icons.storefront_outlined,
                label: '供应商',
                value: expectation.supplierName ?? '—',
              ),
              _InfoLine(
                icon: Icons.warehouse_outlined,
                label: '入库仓库',
                // 订货单不再携带仓库：有建议仓带出建议，否则登记到货时选择。
                value:
                    expectation.warehouseName ??
                    (expectation.suggestedWarehouseName != null
                        ? '建议 ${expectation.suggestedWarehouseName}'
                        : '登记到货时选择'),
              ),
              _InfoLine(
                icon: Icons.event_outlined,
                label: '预计到货',
                value: expectation.expectedDate ?? '未填写',
              ),
              _InfoLine(
                icon: Icons.inventory_outlined,
                label: '数量进度',
                value:
                    '订货 ${procurementQty(expectation.orderedQty)}，已收 ${procurementQty(expectation.acceptedQty)}，待收 ${procurementQty(expectation.effectiveRemainingQty)}',
              ),
              // 已登记待审核在途量：仓库登记保存后、收货审核前可见；
              // 审核通过转品质部检验，任务待全部合格入库后才消失。
              if (expectation.registeredQty > 0)
                _InfoLine(
                  icon: Icons.pending_actions_outlined,
                  label: '在途',
                  value:
                      '已登记待审核 ${procurementQty(expectation.registeredQty)}(审核通过后转品质部检验)',
                ),
              // 部分到货已送检：剩余量还能登记，检查结果在合并页跟踪。
              if (expectation.pendingInspectionReceipts > 0)
                _InfoLine(
                  icon: Icons.fact_check_outlined,
                  label: '已送检',
                  value:
                      '${expectation.pendingInspectionReceipts} 张收货单等待品质结果'
                      '（在「品质部检查结果」页跟踪）',
                ),
              _InfoLine(
                icon: Icons.person_outline_rounded,
                label: '负责人',
                value: expectation.ownerEmployeeName ?? '—',
              ),
              const Divider(height: UtenSpacing.s24),
              Text(
                '${receivableItems.length} 条待收明细',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              // 待收明细：物料编码/系列/库位号/颜色帮助仓库备货对位（价格对仓库不可见）。
              for (final item in receivableItems)
                Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
                  child: Text(
                    [
                      item.goodsCode,
                      item.goodsName,
                      if (item.goodsSeries?.isNotEmpty == true)
                        '系列 ${item.goodsSeries}',
                      if (item.goodsStockPlace?.isNotEmpty == true)
                        '库位 ${item.goodsStockPlace}',
                      if (item.colorName?.isNotEmpty == true)
                        '颜色 ${item.colorName}',
                      if (item.registeredQty > 0)
                        '已登记待审核 ${procurementQty(item.registeredQty)}'
                            '${item.unitName == null ? '' : ' ${item.unitName}'}',
                      '待收 ${procurementQty(item.effectiveRemainingQty)}'
                          '${item.unitName == null ? '' : ' ${item.unitName}'}',
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                switch (_step) {
                  InboundArrivalStep.readyToRegister =>
                    expectation.awaitingReceiptReview
                        ? '本批已登记待送检；「继续送检」完成后再登记剩余量。'
                        : '按实际到货数量登记，保存即送品质部检验。',
                  InboundArrivalStep.draftPendingInspection =>
                    '到货已登记待送检：点「继续送检」完成这一步，送检后由品质部检验入库。',
                  InboundArrivalStep.excessPendingFinance =>
                    '实到超过财务批准量，已隔离：未入库、未生成应付。'
                        '财务定案后可在「到货异常任务中心」一键入库或办理退回。',
                  InboundArrivalStep.awaitingQuality =>
                    '已送检：检查进度与结果请在「品质部检查结果」页查看；'
                        '合格后在该页核对实物和库位确认入库。',
                  InboundArrivalStep.blocked =>
                    '任务数据或服务端授权不完整，请刷新；前端不会代替服务端放行。',
                },
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _step == InboundArrivalStep.excessPendingFinance
                      ? theme.colorScheme.error
                      : _step == InboundArrivalStep.awaitingQuality ||
                            _step == InboundArrivalStep.draftPendingInspection
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        UtenButton(
          key: Key('create-receipt-${expectation.id}'),
          size: UtenButtonSize.large,
          icon: switch (_step) {
            InboundArrivalStep.readyToRegister => Icons.inventory_2_outlined,
            InboundArrivalStep.draftPendingInspection =>
              Icons.fact_check_outlined,
            InboundArrivalStep.excessPendingFinance =>
              Icons.account_balance_outlined,
            _ => Icons.hourglass_empty_outlined,
          },
          onPressed: switch (_step) {
            InboundArrivalStep.readyToRegister => onCreateReceipt,
            InboundArrivalStep.draftPendingInspection => onCompleteRegistration,
            InboundArrivalStep.excessPendingFinance => onOpenExceptions,
            _ => null,
          },
          child: Text(switch (_step) {
            InboundArrivalStep.readyToRegister => '登记实际到货',
            InboundArrivalStep.draftPendingInspection => '继续送检',
            InboundArrivalStep.excessPendingFinance =>
              '超量待财务(${expectation.openArrivalExceptions}) · 去处理',
            InboundArrivalStep.awaitingQuality =>
              '已送检(${expectation.pendingInspectionReceipts}) · 结果见品质检查结果页',
            InboundArrivalStep.blocked => '暂不能登记',
          }),
        ),
      ],
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 20,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: UtenSpacing.s8),
          SizedBox(width: 80, child: Text('$label：')),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: theme.colorScheme.error),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(child: Text(message)),
          const SizedBox(width: UtenSpacing.s8),
          UtenButton(
            size: UtenButtonSize.large,
            type: UtenButtonType.tonal,
            icon: Icons.refresh_rounded,
            onPressed: onRetry,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
