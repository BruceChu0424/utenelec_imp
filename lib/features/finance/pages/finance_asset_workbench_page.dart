import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../models/finance_asset_models.dart';
import '../repositories/finance_asset_overview_repository.dart';
import '../widgets/finance_asset_ledger_panel.dart';
import '../widgets/finance_asset_policy_dialog.dart';
import '../widgets/finance_asset_posting_panel.dart';
import '../widgets/finance_asset_ui.dart';

class FinanceAssetWorkbenchPage extends ConsumerStatefulWidget {
  const FinanceAssetWorkbenchPage({super.key});

  @override
  ConsumerState<FinanceAssetWorkbenchPage> createState() =>
      _FinanceAssetWorkbenchPageState();
}

class _FinanceAssetWorkbenchPageState
    extends ConsumerState<FinanceAssetWorkbenchPage>
    with SingleTickerProviderStateMixin {
  final _overviewGuard = LatestRequestGuard();
  late final TabController _tabs;
  final Set<int> _visitedTabs = <int>{0};
  FinanceAssetWorkbenchOverview? _overview;
  bool _overviewLoading = true;
  String? _overviewError;
  int _refreshToken = 0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this)
      ..addListener(_handleTabChanged);
    _loadOverview();
  }

  @override
  void dispose() {
    _tabs
      ..removeListener(_handleTabChanged)
      ..dispose();
    super.dispose();
  }

  void _handleTabChanged() {
    if (_tabs.indexIsChanging) return;
    setState(() => _visitedTabs.add(_tabs.index));
  }

  FinanceAssetCapabilities _capabilities() {
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    bool has(String permission) =>
        superAdmin || permissions.contains(permission);
    return FinanceAssetCapabilities(
      canView: has(Perm.financeAssetView),
      canEdit: has(Perm.financeAssetEdit),
      canApprove: has(Perm.financeAssetApprove),
      canPost: has(Perm.financeAssetPost),
      canDispose: has(Perm.financeAssetDispose),
      canManagePeriod: has(Perm.financeAssetPeriodManage),
    );
  }

  Future<void> _loadOverview() async {
    final generation = _overviewGuard.begin();
    setState(() {
      _overviewLoading = true;
      _overviewError = null;
    });
    try {
      final result = await ref
          .read(financeAssetOverviewRepositoryProvider)
          .load();
      if (!mounted || !_overviewGuard.isCurrent(generation)) return;
      setState(() {
        _overview = result;
        _overviewLoading = false;
      });
    } catch (_) {
      if (!mounted || !_overviewGuard.isCurrent(generation)) return;
      setState(() {
        _overviewLoading = false;
        _overviewError = '资产总览加载失败，请检查网络后重试';
      });
    }
  }

  Future<void> _refreshAll() async {
    setState(() => _refreshToken++);
    await _loadOverview();
  }

  Future<void> _configurePolicy(FinanceAssetCapabilities capabilities) async {
    final changed = await showFinanceAssetPolicyDialog(
      context,
      canApprove: capabilities.canApprove,
    );
    if (!mounted || !changed) return;
    await _refreshAll();
  }

  @override
  Widget build(BuildContext context) {
    final capabilities = _capabilities();
    if (!capabilities.canView) {
      return Scaffold(
        appBar: const UtenAppBar(title: '资产与待摊'),
        body: UtenEmpty.error(
          message: '无权查看资产与待摊',
          description: '请联系管理员授予资产查看权限。',
        ),
      );
    }
    final policyReady = _overview?.policyReady ?? false;
    final tabBar = TabBar(
      controller: _tabs,
      tabs: const [
        Tab(icon: Icon(Icons.apartment_outlined), text: '固定资产'),
        Tab(icon: Icon(Icons.calendar_month_outlined), text: '长期待摊'),
        Tab(icon: Icon(Icons.fact_check_outlined), text: '月末处理'),
      ],
    );
    // 垂直层级：一级固定区（4 个数据卡片，常驻不滚）→ 可滚动区（提示横幅滚走 →
    // Tab 导航吸顶 → 筛选/内容内滚）。NestedScrollView 协调，页面任意位置上滚
    // 都先收横幅、Tab 顶到卡片下沿后吸顶，之后仅面板内容滚动；下滚反向还原。
    return Scaffold(
      appBar: UtenAppBar(
        title: '资产与待摊',
        subtitle: '专业子账 · 审批 · 折旧摊销 · 期间控制',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.finance),
        ),
        actions: [
          IconButton(
            key: const Key('finance-asset-refresh'),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            tooltip: '刷新资产工作台',
            onPressed: _overviewLoading ? null : _refreshAll,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          padding: const EdgeInsets.only(top: UtenSpacing.s12),
          child: Column(
            children: [
              _metricsSection(capabilities),
              Expanded(
                child: UtenCollapsingHeaderScrollView(
                  collapsingHeader: _bannerSection(capabilities),
                  pinnedHeader: Padding(
                    padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: UtenRadius.lgAll,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      child: tabBar,
                    ),
                  ),
                  pinnedHeaderExtent:
                      tabBar.preferredSize.height + UtenSpacing.s8,
                  body: IndexedStack(
                    index: _tabs.index,
                    children: [
                      FinanceAssetLedgerPanel(
                        key: const ValueKey('fixed-asset-ledger'),
                        ledger: FinanceAssetLedger.fixedAsset,
                        capabilities: capabilities,
                        policyReady: policyReady,
                        refreshToken: _refreshToken,
                      ),
                      if (_visitedTabs.contains(1))
                        FinanceAssetLedgerPanel(
                          key: const ValueKey('deferred-expense-ledger'),
                          ledger: FinanceAssetLedger.deferredExpense,
                          capabilities: capabilities,
                          policyReady: policyReady,
                          refreshToken: _refreshToken,
                        )
                      else
                        const SizedBox.shrink(),
                      if (_visitedTabs.contains(2))
                        FinanceAssetPostingPanel(
                          key: ValueKey('asset-posting-$_refreshToken'),
                          capabilities: capabilities,
                        )
                      else
                        const SizedBox.shrink(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 一级固定区：4 个数据卡片，始终钉在页面顶端，不随滚动位移。
  /// 加载中/加载失败时原地展示骨架与重试入口（与改版前一致）。
  Widget _metricsSection(FinanceAssetCapabilities capabilities) {
    if (_overviewLoading && _overview == null) {
      return const SizedBox(
        height: 116,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_overviewError != null && _overview == null) {
      return SizedBox(
        height: 132,
        child: UtenEmpty.error(
          key: const Key('finance-asset-overview-retry'),
          message: _overviewError,
          actionLabel: '重试',
          onAction: _loadOverview,
        ),
      );
    }
    final overview = _overview!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= UtenBreakpoints.expandedStart
            ? 4
            : 2;
        const spacing = UtenSpacing.s12;
        final width =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            _MetricCard(
              width: width,
              icon: Icons.inventory_2_outlined,
              label: '固定资产原值',
              value:
                  '¥ ${formatFinanceDecimal(overview.metrics.originalValue)}',
            ),
            _MetricCard(
              width: width,
              icon: Icons.account_balance_wallet_outlined,
              label: '固定资产净值',
              value: '¥ ${formatFinanceDecimal(overview.metrics.netBookValue)}',
            ),
            _MetricCard(
              width: width,
              icon: Icons.timelapse_rounded,
              label: '待摊余额',
              value:
                  '¥ ${formatFinanceDecimal(overview.metrics.deferredBalance)}',
            ),
            _MetricCard(
              width: width,
              icon: Icons.rule_folder_outlined,
              label: '待办 / 异常',
              value: overview.metrics.pendingOrExceptionCount.toString(),
            ),
          ],
        );
      },
    );
  }

  /// 可滚动区头部：两条提示横幅，随上滚滑出（被固定卡片遮挡）、下滚拉回。
  /// 顶部固定 s12 间距：无横幅时也保住卡片与 Tab 栏的初始间距。
  Widget _bannerSection(FinanceAssetCapabilities capabilities) {
    final overview = _overview;
    return Column(
      children: [
        const SizedBox(height: UtenSpacing.s12),
        if (overview != null && !overview.policyReady) ...[
          _PolicyBanner(
            missingItems: overview.missingPolicyItems,
            canConfigure: capabilities.canApprove,
            onConfigure: () => _configurePolicy(capabilities),
          ),
          const SizedBox(height: UtenSpacing.s12),
        ],
        if (overview != null && !overview.postedWorkflowsEnabled) ...[
          _OperationalSafetyBanner(blockers: overview.operationalBlockers),
          const SizedBox(height: UtenSpacing.s12),
        ],
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.width,
    required this.icon,
    required this.label,
    required this.value,
  });

  final double width;
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '$label，$value',
      child: Container(
        width: width,
        height: 96,
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: UtenRadius.mdAll,
              ),
              child: Icon(icon, color: theme.colorScheme.onPrimaryContainer),
            ),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      value,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
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

/// 防御性脱敏：把后端可能下发的英文策略键映射成中文友好标签。
/// 即便后端回退成英文键，前端也不会把其直出给用户（防止据此推断库表结构）；
/// 后端正常下发中文时查无命中，原样返回中文。
String _friendlyPolicyLabel(String raw) {
  const labels = <String, String>{
    'FIXED_ASSET_CATEGORY_POLICY': '固定资产类别政策',
    'DEFERRED_EXPENSE_CATEGORY_POLICY': '长期待摊费用类别政策',
  };
  return labels[raw] ?? raw;
}

class _PolicyBanner extends StatelessWidget {
  const _PolicyBanner({
    required this.missingItems,
    required this.canConfigure,
    required this.onConfigure,
  });

  final List<String> missingItems;
  final bool canConfigure;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = missingItems.isEmpty
        ? '分类或会计科目政策尚未就绪'
        : missingItems.take(3).map(_friendlyPolicyLabel).join('、');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.42),
        borderRadius: UtenRadius.lgAll,
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.25),
        ),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: UtenSpacing.s12,
        runSpacing: UtenSpacing.s8,
        children: [
          Icon(Icons.policy_outlined, color: theme.colorScheme.error),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Text('政策未就绪：$detail。可先保存草稿；提交、启用、过账和关账将保持阻断。'),
          ),
          if (canConfigure)
            UtenButton(
              key: const Key('finance-asset-configure-policy'),
              type: UtenButtonType.secondary,
              icon: Icons.settings_outlined,
              onPressed: onConfigure,
              child: const Text('配置政策'),
            ),
        ],
      ),
    );
  }
}

class _OperationalSafetyBanner extends StatelessWidget {
  const _OperationalSafetyBanner({required this.blockers});

  final List<String> blockers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      label: '资产核心落账安全门禁已关闭',
      child: Container(
        key: const Key('finance-asset-posted-workflow-gate'),
        width: double.infinity,
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.55),
          borderRadius: UtenRadius.lgAll,
          border: Border.all(
            color: theme.colorScheme.tertiary.withValues(alpha: 0.28),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.lock_clock_outlined,
              color: theme.colorScheme.onTertiaryContainer,
            ),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '核心落账暂未开放',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  const Text(
                    '可配置类别、建立草稿并完成前置复核；初始确认、处置和提前终止会继续由服务端阻断，'
                    '直到专用的制单—复核—过账—反冲链路验收完成。配置会计政策不能解除此安全门禁。',
                  ),
                  if (blockers.isNotEmpty) ...[
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '服务端阻断项：${blockers.length} 项',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
