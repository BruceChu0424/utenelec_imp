import 'package:flutter/material.dart';
import 'dart:async';
import '../../../shared/drafts/form_draft_category.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../shared/drafts/form_draft_dialog_resume.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_collapsible_content.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../models/finance_asset_models.dart';
import '../repositories/finance_asset_overview_repository.dart';
import '../widgets/finance_asset_ledger_panel.dart';
import '../widgets/finance_asset_form.dart';
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
    extends ConsumerState<FinanceAssetWorkbenchPage> {
  final _overviewGuard = LatestRequestGuard();
  int _tabIndex = 0;
  bool _restrictionsExpanded = false;
  bool _ledgerFullscreen = false;
  final _creationTokens = [0, 0];
  final Set<int> _visitedTabs = <int>{0};
  FinanceAssetWorkbenchOverview? _overview;
  bool _overviewLoading = true;
  String? _overviewError;
  int _refreshToken = 0;
  Map<int, Completer<void>> _refreshCompletions = {};

  @override
  void initState() {
    super.initState();
    _loadOverview();
  }

  @override
  void dispose() {
    for (final completion in _refreshCompletions.values) {
      if (!completion.isCompleted) completion.complete();
    }
    super.dispose();
  }

  void _selectSection(int index) {
    setState(() {
      _tabIndex = index;
      _visitedTabs.add(index);
    });
  }

  FinanceAssetCapabilities _capabilities() {
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    bool has(String permission) =>
        superAdmin || permissions.contains(permission);
    return FinanceAssetCapabilities(
      canView: has(Perm.financeAssetView),
      canEdit: has(Perm.financeAssetEdit),
      canDelete: has(Perm.financeAssetDelete),
      canApprove: has(Perm.financeAssetApprove),
      canPost: has(Perm.financeAssetPost),
      canReverse: has(Perm.financeAssetReverse),
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
    final completions = {
      for (final tab in _visitedTabs)
        if (tab < 3) tab: Completer<void>(),
    };
    setState(() {
      _refreshCompletions = completions;
      _refreshToken++;
    });
    await Future.wait([
      _loadOverview(),
      for (final completion in completions.values) completion.future,
    ]);
  }

  Future<void> _configurePolicy(FinanceAssetCapabilities capabilities) async {
    final changed = await showFinanceAssetPolicyDialog(
      context,
      canApprove: capabilities.canApprove,
    );
    if (!mounted || !changed) return;
    await _refreshAll();
  }

  Future<void> _createAsset() async {
    final ledger = _tabIndex == 0
        ? FinanceAssetLedger.fixedAsset
        : FinanceAssetLedger.deferredExpense;
    final saved = await showFinanceAssetForm(context, ledger: ledger);
    if (mounted && saved) {
      _creationTokens[ledger == FinanceAssetLedger.fixedAsset ? 0 : 1]++;
      await _refreshAll();
    }
  }

  void _onLedgerFullscreenChanged(bool fullscreen) {
    if (mounted && _ledgerFullscreen != fullscreen) {
      setState(() => _ledgerFullscreen = fullscreen);
    }
  }

  @override
  Widget build(BuildContext context) => FormDraftDialogResume(
    descriptor: FormDraftCatalog.assetPolicy,
    onResume: (_) async {
      await showFinanceAssetPolicyDialog(
        context,
        canApprove:
            true, // Resume host already enforces the registered policy authority.
      );
      if (mounted) await _refreshAll();
    },
    child: _buildPolicyDraftHost(context),
  );

  Widget _buildPolicyDraftHost(BuildContext context) {
    final capabilities = _capabilities();
    if (!capabilities.canView) {
      for (final completion in _refreshCompletions.values) {
        if (!completion.isCompleted) completion.complete();
      }
      return Scaffold(
        appBar: const UtenAppBar(title: '资产与待摊'),
        body: UtenEmpty.error(
          message: '无权查看资产与待摊',
          description: '请联系管理员授予资产查看权限。',
        ),
      );
    }
    final policyReady = _overview?.policyReady ?? false;
    final sections = UtenFilterToolbar<int>(
      key: const Key('finance-asset-sections'),
      selected: {_tabIndex},
      onSelectionChanged: _selectSection,
      autoSelectBadge: false,
      segments: [
        const UtenFilterSegment(value: 0, label: '固定资产'),
        const UtenFilterSegment(value: 1, label: '长期待摊'),
        const UtenFilterSegment(value: 2, label: '月末处理'),
        UtenFilterSegment(
          value: 3,
          label: '政策草稿',
          count: ref.watch(
            formDraftCategoryVisibleCountProvider(
              const FormDraftCategoryScope(
                routePath: '/finance/assets',
                query: {'draftForm': 'assetPolicy'},
              ),
            ),
          ),
          countForm: UtenSegmentCountForm.actionable,
        ),
      ],
    );
    // Overview and restrictions scroll away to leave room for the ledger.
    // Compact/short viewports use the shared whole-page scrolling fallback.
    return Scaffold(
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton:
          capabilities.canEdit && _tabIndex < 2 && !_ledgerFullscreen
          ? UtenFloatingActionGroup(
              children: [
                UtenButton(
                  key: Key(
                    'finance-asset-create-${_tabIndex == 0 ? 'FIXED_ASSET' : 'DEFERRED_EXPENSE'}',
                  ),
                  size: UtenButtonSize.large,
                  icon: Icons.add_rounded,
                  onPressed: _createAsset,
                  child: Text(_tabIndex == 0 ? '新建固定资产' : '新建长期待摊'),
                ),
              ],
            )
          : null,
      appBar: UtenAppBar(
        title: '资产与待摊',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.finance),
        ),
        actions: [
          UtenRefreshButton(
            busy: _overviewLoading,
            key: const Key('finance-asset-refresh'),
            tooltip: '刷新资产工作台',
            onRefresh: _refreshAll,
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          padding: const EdgeInsets.only(top: UtenSpacing.s12),
          child: UtenCollapsingHeaderScrollView(
            compactBodyMinHeight: 640,
            collapsingHeader: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _metricsSection(capabilities),
                _bannerSection(capabilities),
                sections,
                const SizedBox(height: UtenSpacing.s12),
              ],
            ),
            body: IndexedStack(
              index: _tabIndex,
              children: [
                FinanceAssetLedgerPanel(
                  key: const ValueKey('fixed-asset-ledger'),
                  ledger: FinanceAssetLedger.fixedAsset,
                  capabilities: capabilities,
                  policyReady: policyReady,
                  refreshToken: _refreshToken,
                  creationToken: _creationTokens[0],
                  onFullscreenChanged: _onLedgerFullscreenChanged,
                  refreshCompletion: _refreshCompletions[0],
                ),
                if (_visitedTabs.contains(1))
                  FinanceAssetLedgerPanel(
                    key: const ValueKey('deferred-expense-ledger'),
                    ledger: FinanceAssetLedger.deferredExpense,
                    capabilities: capabilities,
                    policyReady: policyReady,
                    refreshToken: _refreshToken,
                    creationToken: _creationTokens[1],
                    onFullscreenChanged: _onLedgerFullscreenChanged,
                    refreshCompletion: _refreshCompletions[1],
                  )
                else
                  const SizedBox.shrink(),
                if (_visitedTabs.contains(2))
                  FinanceAssetPostingPanel(
                    key: ValueKey('asset-posting-$_refreshToken'),
                    capabilities: capabilities,
                    refreshCompletion: _refreshCompletions[2],
                  )
                else
                  const SizedBox.shrink(),
                if (_visitedTabs.contains(3))
                  const FormDraftCategoryList(
                    scope: FormDraftCategoryScope(
                      routePath: '/finance/assets',
                      query: {'draftForm': 'assetPolicy'},
                    ),
                    // 本页已有联动容器，草稿表直接
                    // 拾取外层注入的控制器，不再自建折叠容器。
                    linkedScroll: false,
                  )
                else
                  const SizedBox.shrink(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// One quiet summary band, with two columns on narrow screens.
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
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: UtenRadius.lgAll,
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Wrap(
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
                value:
                    '¥ ${formatFinanceDecimal(overview.metrics.netBookValue)}',
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
                label: '待办 / 有问题',
                value: overview.metrics.pendingOrExceptionCount.toString(),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _bannerSection(FinanceAssetCapabilities capabilities) {
    final overview = _overview;
    if (overview == null ||
        (overview.policyReady && overview.postedWorkflowsEnabled)) {
      return const SizedBox(height: UtenSpacing.s12);
    }
    final theme = Theme.of(context);
    final policyBlocked = !overview.policyReady;
    final postingBlocked = !overview.postedWorkflowsEnabled;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: UtenSpacing.s16,
              runSpacing: UtenSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (policyBlocked)
                  _RestrictionLabel(
                    icon: Icons.policy_outlined,
                    label: '政策未就绪',
                    color: theme.colorScheme.error,
                  ),
                if (postingBlocked)
                  _RestrictionLabel(
                    key: const Key('finance-asset-posted-workflow-gate'),
                    icon: Icons.lock_outline,
                    label: '核心落账暂未开放',
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                UtenButton(
                  key: const Key('finance-asset-restrictions-toggle'),
                  type: UtenButtonType.ghost,
                  icon: _restrictionsExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  onPressed: () => setState(
                    () => _restrictionsExpanded = !_restrictionsExpanded,
                  ),
                  child: Text(_restrictionsExpanded ? '收起说明' : '查看限制'),
                ),
                if (policyBlocked && capabilities.canApprove)
                  UtenButton(
                    key: const Key('finance-asset-configure-policy'),
                    type: UtenButtonType.secondary,
                    icon: Icons.settings_outlined,
                    onPressed: () => _configurePolicy(capabilities),
                    child: const Text('配置政策'),
                  ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              policyBlocked ? '可先保存草稿；提交、启用、过账和关账需完成政策配置。' : '可建立草稿并完成前置复核。',
              style: theme.textTheme.bodySmall,
            ),
            if (postingBlocked)
              Text('初始确认、处置和提前终止暂不可用。', style: theme.textTheme.bodySmall),
            UtenCollapsibleContent(
              expanded: _restrictionsExpanded,
              maintainState: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Divider(height: UtenSpacing.s24),
                  if (policyBlocked)
                    Text(
                      '待配置：${overview.missingPolicyItems.isEmpty ? '类别与会计科目政策' : overview.missingPolicyItems.map(_friendlyPolicyLabel).join('、')}。',
                    ),
                  if (postingBlocked) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    const Text('落账功能需完成独立审批与反冲流程验收后开放；配置会计政策不能解除此安全门禁。'),
                    if (overview.operationalBlockers.isNotEmpty)
                      Text('待完成事项：${overview.operationalBlockers.length} 项'),
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

class _RestrictionLabel extends StatelessWidget {
  const _RestrictionLabel({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
  });
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: UtenSpacing.s8),
      Flexible(
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(color: color),
        ),
      ),
    ],
  );
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
        constraints: const BoxConstraints(minHeight: 80),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          children: [
            if (width >= 220) ...[
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: UtenSpacing.s12),
            ],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    value,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
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
