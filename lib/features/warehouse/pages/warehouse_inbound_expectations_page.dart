import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../shared/auth/permissions.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/widgets/metric_filter_cards.dart';
import '../providers/procurement_inbound_count_providers.dart';
import '../repositories/procurement_inbound_repository.dart';
import '../repositories/procurement_inspection_repository.dart';

class WarehouseInboundExpectationsPage extends ConsumerStatefulWidget {
  const WarehouseInboundExpectationsPage({super.key});

  @override
  ConsumerState<WarehouseInboundExpectationsPage> createState() =>
      _WarehouseInboundExpectationsPageState();
}

class _WarehouseInboundExpectationsPageState
    extends ConsumerState<WarehouseInboundExpectationsPage> {
  PagedResult<InboundExpectation>? _result;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;

  /// 「待品质部批准」状态卡是否处于说明态：该卡不筛列表，点击只在下方
  /// 提示条切换品质部口径说明；再点一次或点「全部待到货」恢复默认提示。
  bool _inspectionHintShown = false;

  /// 搜索关键字（订货单号/供应商/货品编码或名称），UtenSearchBar 300ms 防抖后回写。
  String _keyword = '';

  /// 全部待到货计数（后端全量口径）；null = 尚未返回，卡片显示 '—'。
  int? _totalCount;

  /// 待检处置卡角标：仍有 PENDING/PARTIAL 明细的收货单张数；null = 尚未返回。
  int? _inspectionPendingCount;

  /// 待检处置卡仅对有查看权限者可见（服务端接口独立鉴权兜底）。
  bool get _canViewInspection =>
      ref.read(isSuperAdminProvider) ||
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.procurementInspectionView);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  /// 当前选中卡的口径提示文案：卡片内不放说明文字（与财务审批任务中心的指标卡
  /// 一致），口径说明放卡片下方的整行提示条，点击卡片随选中态切换。
  String get _scopeHint => _inspectionHintShown
      ? '待检处置已移交品质部：到货登记审核通过后转品质部检验'
            '(品质任务中心 → 待检处置)，检验通过后自动入库，仓库无需跟进。'
      : '只显示财务已批准、可准备收货的采购和委外订货单。';

  /// 搜索：防抖后回到第 1 页重新加载（只让最新 GET 回写，见 _requestVersion）。
  void _applySearch(String value) {
    if (value == _keyword) return;
    setState(() => _keyword = value);
    _load(1);
  }

  Future<void> _load(int page) async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(procurementInboundRepositoryProvider);
      final result = await repo.expectations(page: page, keyword: _keyword);
      // 全量计数失败不阻断列表（卡片降级为 '—'）。
      repo
          .expectationCount()
          .then((count) {
            if (mounted) setState(() => _totalCount = count);
          })
          .catchError((_) {});
      // 待检处置卡角标同理：失败仅显示 '—'。
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
  /// 链路）——中途退出的仓库人员在任务卡上直接完成停止的步骤，不进采购/委外单据页。
  Future<void> _completeRegistration(InboundExpectation expectation) async {
    if (expectation.draftReceiptIds.isEmpty) return;
    final confirmed = await showUtenReviewerConfirmDialog(
      context,
      title: '继续送检',
      actionLabel: '送检',
      confirmLabel: '确认送检',
      message:
          '将把已登记的到货数量送品质部待检(IQC)：检验合格放行后库存增加；'
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

  /// 到货登记/送检结果的下一步提示（正常 → 品质放行自动入库；超量 → 财务定案）。
  void _announceRegistration(WarehouseArrivalRegistration registration) {
    switch (registration.outcome) {
      case WarehouseArrivalRegistrationOutcome.submittedForInspection:
        context.appSuccess(
          '到货已送检(${registration.receiptBillNo ?? ''})：'
          '品质部检验合格后自动入库，无需仓库跟进',
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
    return Scaffold(
      appBar: UtenAppBar(
        title: '预计到货任务中心',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && result != null,
              onPressed: _loading ? null : () => _load(result?.page ?? 1),
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && result == null
            ? const UtenSkeletonList()
            : _error != null && result == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: () => _load(1),
              )
            : _buildList(result),
      ),
    );
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
    return UtenContentContainer.narrow(
      child: RefreshIndicator(
        onRefresh: () => _load(result.page),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
          children: [
            // 搜索：订货单号/供应商/货品编码或名称；防抖期间作废旧请求，
            // 只让最新 GET 回写（onInputChanged 先 bump 版本号）。
            UtenSearchBar(
              key: const Key('inbound-expectation-search'),
              hint: '搜索订货单号 / 供应商 / 货品',
              initialValue: _keyword,
              onInputChanged: (_) => _requestVersion++,
              onChanged: _applySearch,
            ),
            const SizedBox(height: UtenSpacing.s12),
            // 顶部指标卡与任务工作台统一（MetricFilterCards）：「全部待到货」计数走
            // 后端全量口径；「待品质部批准」为只读状态卡（不筛列表），点击在下方
            // 提示条切换品质部口径说明。卡片内不放说明文字（与财务审批任务中心的
            // 指标卡一致），口径提示放下方整行提示条，点击卡片随选中态切换。
            Semantics(
              header: true,
              label: '共有 ${result.total} 张待到货订货单',
              child: MetricFilterCards(
                key: const Key('inbound-expectation-metric-cards'),
                items: [
                  MetricFilterCardItem(
                    key: 'all',
                    label: '全部待到货',
                    value: _totalCount,
                    icon: Icons.local_shipping_outlined,
                    selected: !_inspectionHintShown,
                    onTap: () {
                      // 列表恒为全部视图：再点只收回品质部说明态
                      // （与「再点已选卡回全部」同语义）。
                      if (_inspectionHintShown) {
                        setState(() => _inspectionHintShown = false);
                      }
                    },
                  ),
                  // 待检处置已移交品质部：本卡为仓库侧只读状态卡（不筛列表），
                  // 点击在下方提示条显示品质部口径说明；角标 = 待检收货单张数
                  // （无检验查看权限时不拉取，显示 '—'）。
                  MetricFilterCardItem(
                    key: 'inspection',
                    label: '待品质部批准',
                    value: _inspectionPendingCount,
                    tone: 'error',
                    icon: Icons.fact_check_outlined,
                    selected: _inspectionHintShown,
                    onTap: () => setState(
                      () => _inspectionHintShown = !_inspectionHintShown,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            _ScopeHintBanner(message: _scopeHint),
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '刷新失败：$_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: UtenSpacing.s16),
            if (result.items.isEmpty)
              SizedBox(
                height: 380,
                child: UtenEmpty(
                  icon: Icons.inventory_2_outlined,
                  message: _keyword.isNotEmpty
                      ? '没有匹配「$_keyword」的预计到货'
                      : '目前没有预计到货',
                  description: _keyword.isNotEmpty
                      ? '换个关键字试试，或清除搜索查看全部。'
                      : '财务批准采购或委外订货单后，会自动出现在这里。',
                ),
              )
            else
              for (var i = 0; i < result.items.length; i++) ...[
                _ExpectationCard(
                  key: Key('inbound-expectation-${result.items[i].id}'),
                  expectation: result.items[i],
                  onCreateReceipt: () => _createReceipt(result.items[i]),
                  onCompleteRegistration: () =>
                      _completeRegistration(result.items[i]),
                ),
                if (i != result.items.length - 1)
                  const SizedBox(height: UtenSpacing.s12),
              ],
            if (result.totalPages > 1) ...[
              const SizedBox(height: UtenSpacing.s20),
              _Pager(
                page: result.page,
                totalPages: result.totalPages,
                loading: _loading,
                onPage: _load,
              ),
            ],
            const SizedBox(height: UtenSpacing.s24),
          ],
        ),
      ),
    );
  }
}

class _ExpectationCard extends StatelessWidget {
  const _ExpectationCard({
    super.key,
    required this.expectation,
    required this.onCreateReceipt,
    required this.onCompleteRegistration,
  });

  final InboundExpectation expectation;
  final VoidCallback onCreateReceipt;

  /// 「已登记待送检」恢复入口：草稿收货单一键继续送检（断点续走，不进采购模块）。
  final VoidCallback onCompleteRegistration;

  InboundArrivalStep get _step => expectation.arrivalStep;

  static String _stepLabel(InboundArrivalStep step) => switch (step) {
    InboundArrivalStep.readyToRegister => '待登记到货',
    InboundArrivalStep.draftPendingInspection => '已登记 · 待送检',
    InboundArrivalStep.excessPendingFinance => '超量 · 待财务审批',
    InboundArrivalStep.awaitingQuality => '已送检 · 待品质检验',
    InboundArrivalStep.blocked => '暂不能登记',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UtenStatusBadge(
                  label: '${expectation.orderType.label}到货',
                  type:
                      expectation.orderType ==
                          ProcurementInboundOrderType.purchase
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
            const SizedBox(height: UtenSpacing.s12),
            _InfoLine(
              icon: Icons.storefront_outlined,
              label: '供应商',
              value: expectation.supplierName ?? '—',
            ),
            _InfoLine(
              icon: Icons.warehouse_outlined,
              label: '入库仓库',
              // 订货单不再携带仓库：入库仓库在「登记实际到货」时选择。
              value: expectation.warehouseName ?? '登记到货时选择',
            ),
            _InfoLine(
              icon: Icons.event_outlined,
              label: '预计到货',
              value: expectation.expectedDate ?? '未填写',
            ),
            _InfoLine(
              icon: Icons.inventory_outlined,
              label: '数量',
              value:
                  '订货 ${procurementQty(expectation.orderedQty)}，已收 ${procurementQty(expectation.acceptedQty)}，待收 ${procurementQty(expectation.effectiveRemainingQty)}',
            ),
            // 已登记待审核在途量：仓库登记保存后、收货审核前可见；
            // 审核通过转品质部检验（待品质部批准卡），任务待全部合格入库后才消失。
            if (expectation.registeredQty > 0)
              _InfoLine(
                icon: Icons.pending_actions_outlined,
                label: '在途',
                value:
                    '已登记待审核 ${procurementQty(expectation.registeredQty)}(审核通过后转品质部检验)',
              ),
            const Divider(height: UtenSpacing.s24),
            Text(
              '${expectation.items.where((item) => item.canReceive).length} 条待收明细',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            // 待收明细：物料编码/系列/库位号/颜色帮助仓库备货对位（价格对仓库不可见）。
            for (final item in expectation.items.where((i) => i.canReceive))
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
            const SizedBox(height: UtenSpacing.s8),
            SizedBox(
              width: double.infinity,
              child: UtenButton(
                key: Key('create-receipt-${expectation.id}'),
                size: UtenButtonSize.large,
                icon: switch (_step) {
                  InboundArrivalStep.readyToRegister =>
                    Icons.inventory_2_outlined,
                  InboundArrivalStep.draftPendingInspection =>
                    Icons.fact_check_outlined,
                  InboundArrivalStep.excessPendingFinance =>
                    Icons.account_balance_outlined,
                  _ => Icons.hourglass_empty_outlined,
                },
                onPressed: switch (_step) {
                  InboundArrivalStep.readyToRegister => onCreateReceipt,
                  InboundArrivalStep.draftPendingInspection =>
                    onCompleteRegistration,
                  InboundArrivalStep.excessPendingFinance => () => context.go(
                    RouteName.warehouseArrivalExceptions,
                  ),
                  _ => null,
                },
                child: Text(switch (_step) {
                  InboundArrivalStep.readyToRegister => '登记实际到货',
                  InboundArrivalStep.draftPendingInspection => '继续送检',
                  InboundArrivalStep.excessPendingFinance =>
                    '超量待财务(${expectation.openArrivalExceptions}) · 去处理',
                  InboundArrivalStep.awaitingQuality =>
                    '待品质检验(${expectation.pendingInspectionReceipts})',
                  InboundArrivalStep.blocked => '暂不能登记',
                }),
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              switch (_step) {
                InboundArrivalStep.readyToRegister =>
                  expectation.awaitingReceiptReview
                      ? '本批已登记待送检；上方「继续送检」完成后再登记剩余量。'
                      : '按实际到货数量登记，保存即送品质部检验。',
                InboundArrivalStep.draftPendingInspection =>
                  '到货已登记待送检：点「继续送检」完成这一步，送检后由品质部检验入库。',
                InboundArrivalStep.excessPendingFinance =>
                  '实到超过财务批准量，已隔离：未入库、未生成应付。'
                      '财务定案后可在「到货异常任务中心」一键入库或办理退回。',
                InboundArrivalStep.awaitingQuality =>
                  '已送检待品质部放行：检验合格后自动入库存，仓库无需操作。',
                InboundArrivalStep.blocked => '任务数据或服务端授权不完整，请刷新；前端不会代替服务端放行。',
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

class _Pager extends StatelessWidget {
  const _Pager({
    required this.page,
    required this.totalPages,
    required this.loading,
    required this.onPage,
  });
  final int page;
  final int totalPages;
  final bool loading;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        UtenButton(
          size: UtenButtonSize.large,
          type: UtenButtonType.tonal,
          icon: Icons.chevron_left_rounded,
          onPressed: !loading && page > 1 ? () => onPage(page - 1) : null,
          child: const Text('上一页'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
          child: Text('第 $page / $totalPages 页'),
        ),
        UtenButton(
          size: UtenButtonSize.large,
          type: UtenButtonType.tonal,
          icon: Icons.chevron_right_rounded,
          onPressed: !loading && page < totalPages
              ? () => onPage(page + 1)
              : null,
          child: const Text('下一页'),
        ),
      ],
    );
  }
}

/// 口径提示条：指标卡下方整行说明（与财务审批任务中心同款布局），
/// 浅蓝 info 容器色（灰底 + hover 会被误读成「灰色面板」）。
class _ScopeHintBanner extends StatelessWidget {
  const _ScopeHintBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final background = isDark
        ? UtenColors.infoContainerDark
        : UtenColors.infoContainer;
    final foreground = isDark
        ? UtenColors.onInfoContainerDark
        : UtenColors.onInfoContainer;
    return Semantics(
      container: true,
      label: '筛选口径：$message',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: foreground.withValues(alpha: 0.25)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, color: foreground),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
