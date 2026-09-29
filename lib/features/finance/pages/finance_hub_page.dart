// 钱流管理入口页（hub）—— 四个分组：
//  ① 任务中心：业务审核中心（销售订单确认/订单修改/出货/订货/超量到货/IQC 退回
//     六个队列在页内分段办理，2026-09-18 由 6 张卡合并为 1 张卡）
//     报价核价(ADR-134)：销售报价由财务定价格和折扣，确认后销售才能转订货单；
//     单独一张卡(不是审核放行而是改价，页面与认领口径不同)，红徽章 = 待核价张数
//  ② 新建单据：销售收款/采购付款/一般费用/其它收入/银行存取款
//  ③ 设置与台账：报销设置/支票管理/资产
//  ④ 钱流报表：应收应付台账/对账单/流水账
// 卡片统一用 UtenHubCard（图标统一 40×40），
// 计数口径（准则 14-徽章与计数口径）：
//   · 「业务审核中心」卡挂右上角红色待办徽章(全部审核队列之和，服务端徽章目录
//     financeAuditCenter 入口算好，ADR-108；「订单修改」是「销售订单确认」的队列切片，
//     总数只计一次）。原 6 张队列卡的旧路由保留，通知深链仍直达具体队列。
//   · 新建单据卡不挂徽章；草稿仍在新建页草稿按钮与列表分段显示红数，
//     「资料草稿」面板顶部另有 5 类钱流草稿的下钻入口（深链列表草稿段）。
//   · 报表区 10 张卡是浏览型入口，不挂任何计数。
//   · 顶栏右上角挂本模块累计（业务审核、报销审批与钱流草稿之和）。
//   · **本 hub 刻意一枚黄色「进行中」徽章都不挂, 顶栏也没有黄药丸**(ADR-100 §2.4):
//     财务的活清一色是审批队列, 一张单要么还在等财务动手(红, 已经数了), 要么财务
//     已经放行 / 已经退回 —— 球落到采购、仓库、销售那几张卡上, 由它们的在办数报出来。
//     在钱流再数一遍就是跨卡双计。想给这里补黄色之前, 先回答「这批单在别的模块的
//     黄数里出现过吗」; 答案是会, 所以不补。
//     页**内**分段是另一回事: 分段计数永不进徽章入口, 销售订单确认页的「已驳回」段
//     就挂黄色, 那是本页自己的进度指示, 不上卷。
// 支票管理 = 账户 account_type=CHECK/FOREIGN_CHECK 的过滤视图（不单独模块），
// 入口指向 /finance/checks（由用户在 app_router 接到 AccountPage(initialAccountTypeFilter:'CHECK')）。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/drafts/form_draft_category.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_module_badges.dart';
import '../../../components/cards/uten_hub_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/draft_counts_provider.dart';
import '../config/finance_doc_config.dart';
import '../models/finance_doc.dart';
import '../widgets/finance_audit_center_badge.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/badges/badge_scope.dart';

class FinanceHubPage extends ConsumerStatefulWidget {
  const FinanceHubPage({super.key});
  @override
  ConsumerState<FinanceHubPage> createState() => _FinanceHubPageState();
}

class _FinanceHubPageState extends ConsumerState<FinanceHubPage> {
  bool _showDrafts = false;
  // 「资料草稿」面板只装资料类(币种/账户/结算方式/收付款类别)的本地草稿；
  // 5 类钱流单据草稿走面板顶部的 [_MoneyFlowDraftEntries] 下钻（业务草稿归
  // 各列表草稿段），资产草稿(固定资产/长期待摊/政策)落点在资产工作台
  //（「政策草稿」Tab 与台账「草稿」计数筛选）——都不混进资料分区。
  static const _draftScope = FormDraftCategoryScope(
    module: BadgeModule.finance,
    excludeKinds: {
      'financeReceipt',
      'financePayment',
      'financeExpense',
      'financeOtherIncome',
      'financeBankTransfer',
    },
    excludeRoutes: {'/finance/assets/new', '/finance/assets'},
  );
  Widget _withDraftCategory(Widget body) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      UtenFilterToolbar<bool>(
        segmentsKey: const Key('finance-hub-categories'),
        segments: [
          const UtenFilterSegment(value: false, label: '业务入口'),
          UtenFilterSegment(
            value: true,
            label: '资料草稿',
            count: ref.watch(
              formDraftCategoryVisibleCountProvider(_draftScope),
            ),
            countForm: UtenSegmentCountForm.actionable,
          ),
        ],
        selected: {_showDrafts},
        onSelectionChanged: (value) => setState(() => _showDrafts = value),
      ),
      Expanded(
        child: _showDrafts
            ? const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _MoneyFlowDraftEntries(),
                  Expanded(child: FormDraftCategoryList(scope: _draftScope)),
                ],
              )
            : body,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    // 返回即刷新：回到本 hub 时按需重拉徽章汇总(本端写过数据或超过 30 秒，ADR-108)。
    ref.onPageResume(RouteName.finance, () => refreshBadges(ref));
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    // 卡片显隐 = hub 目录登记的落点 + 路由守卫(与 /finance 入口守卫同源，ADR-109)；
    // 业务审核中心的五类队列在页内按各自查看码分段，入口按它自己的路由守卫。
    bool canOpen(String location) =>
        hubCardAllowed(RouteName.finance, location, permissions, superAdmin);
    final canOpenAuditCenter = canOpen(RouteName.financeAudits);
    final canOpenQuoteReview = canOpen(RouteName.financeQuoteReview);
    final canHandleExpense = canOpen('/expense/approval');
    List<_Entry> visible(List<_Entry> entries) => entries
        .where((entry) => canOpen(entry.location))
        .toList(growable: false);
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.financeHubTitle,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
        actions: const [
          // 本模块累计：服务端徽章目录对钱流容器全部入口算好的和(含本模块 5 类
          // 草稿，ADR-108)，页面里不做加法。0 时组件自身不渲染。
          UtenModuleBadges(module: BadgeModule.finance),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: _withDraftCategory(
            ListView(
              padding: EdgeInsets.only(
                top: UtenSpacing.s12,
                // compact 悬浮胶囊避让：滚到底末卡要能越过胶囊
                bottom: context.breakpoint.isCompact
                    ? math.max(
                        UtenSpacing.s16,
                        UtenCapsuleNavScope.occlusionOf(context),
                      )
                    : UtenSpacing.s40,
              ),
              children: [
                if (canOpenAuditCenter ||
                    canOpenQuoteReview ||
                    canHandleExpense) ...[
                  _section(context, theme, l10n.hubSectionTaskCenter, [
                    // 2026-09-18 合并：原 6 张审核队列卡（销售订单财务确认/销售订单
                    // 修改/出货财务审核/订货审批/超量到货审批/IQC 不合格退回与贷项）
                    // 并为一张「业务审核中心」卡，队列在页内按权限分段显示；
                    // 角标 = 五类队列待办之和（FinanceAuditCenterBadge 走注册表）。
                    if (canOpenAuditCenter)
                      const _Entry(
                        icon: Icons.fact_check_outlined,
                        label: '业务审核中心',
                        description:
                            '销售订单 · 订单修改 · 出货 · 订货 · 超量到货 · IQC 退回，一站式审核',
                        location: RouteName.financeAudits,
                        badgeScope: BadgeScope.entry(
                          BadgeEntry.financeAuditCenter,
                        ),
                        badge: FinanceAuditCenterBadge(),
                      ),
                    // 报价核价(ADR-134)：红徽章 = 等财务定价确认的报价。
                    if (canOpenQuoteReview)
                      _Entry(
                        icon: Icons.price_check_outlined,
                        label: l10n.quoteFinanceHubTitle,
                        description: l10n.quoteFinanceHubSubtitle,
                        location: RouteName.financeQuoteReview,
                        badgeScope: const BadgeScope.entry(
                          BadgeEntry.financeQuoteReview,
                        ),
                      ),
                    if (canHandleExpense)
                      _Entry(
                        icon: Icons.receipt_long_outlined,
                        label: l10n.expenseFlowApprovalTitle,
                        description: l10n.expenseFlowApprovalEntryDescription,
                        location: '/expense/approval',
                        badgeScope: const BadgeScope.entry(
                          BadgeEntry.expenseFinance,
                        ),
                      ),
                  ]),
                  const SizedBox(height: UtenSpacing.s16),
                ],
                // 2026-09-24 三段式：任务中心 → 新建单据 → 设置与台账 → 报表中心。
                _section(
                  context,
                  theme,
                  '新建单据',
                  visible([
                    _Entry(
                      icon: Icons.south_west_outlined,
                      label: '新建${l10n.financeHubDocReceipt}',
                      description: l10n.financeHubDocReceiptSub,
                      location: RoutePath.financeDocNew('receipts'),
                    ),
                    _Entry(
                      icon: Icons.north_east_outlined,
                      label: '新建${l10n.financeHubDocPayment}',
                      description: l10n.financeHubDocPaymentSub,
                      location: RoutePath.financeDocNew('payments'),
                    ),
                    _Entry(
                      icon: Icons.outbound_outlined,
                      label: '新建${l10n.financeHubDocExpense}',
                      description: l10n.financeHubSubAllocatedByDept,
                      location: RoutePath.financeDocNew('expenses'),
                    ),
                    _Entry(
                      icon: Icons.add_circle_outline,
                      label: '新建${l10n.financeHubDocIncome}',
                      description: l10n.financeHubSubAllocatedByDept,
                      location: RoutePath.financeDocNew('incomes'),
                    ),
                    _Entry(
                      icon: Icons.swap_horiz_rounded,
                      label: '新建${l10n.financeHubDocBankTransfer}',
                      description: l10n.financeHubDocBankTransferSub,
                      location: RoutePath.financeDocNew('bank-transfers'),
                    ),
                  ]),
                ),
                const SizedBox(height: UtenSpacing.s16),
                // 2026-09-24 三段式：设置与台账（浏览管理卡，不挂数；不属于新建区）。
                _section(
                  context,
                  theme,
                  '设置与台账',
                  visible([
                    _Entry(
                      icon: Icons.tune_outlined,
                      label: l10n.expenseFlowSettingsTitle,
                      description: l10n.expenseFlowSettingsEntryDescription,
                      location: '/expense/settings',
                    ),
                    _Entry(
                      icon: Icons.receipt_long_outlined,
                      label: l10n.financeHubDocCheck,
                      description: l10n.financeHubDocCheckSub,
                      location: '/finance/checks',
                    ),
                    _Entry(
                      icon: Icons.apartment_rounded,
                      label: l10n.financeHubDocAssets,
                      description: l10n.financeHubDocAssetsSub,
                      location: RouteName.financeAssets,
                    ),
                  ]),
                ),
                const SizedBox(height: UtenSpacing.s16),
                _section(
                  context,
                  theme,
                  '报表中心',
                  visible([
                    const _Entry(
                      icon: Icons.payments_outlined,
                      label: '应付结算',
                      description: '采购与委外应付、已付、抵销、未付及到期跟踪',
                      location: RouteName.financePayables,
                    ),
                    _Entry(
                      icon: Icons.account_balance_wallet_outlined,
                      label: l10n.financeHubReportArAp,
                      description: l10n.financeHubReportArApSub,
                      location: RouteName.financeReportOverview,
                    ),
                    _Entry(
                      icon: Icons.list_alt_outlined,
                      label: l10n.financeHubReportDetail,
                      description: l10n.financeHubReportDetailSub,
                      location: RouteName.financeReportDetail,
                    ),
                    _Entry(
                      icon: Icons.bar_chart_outlined,
                      label: l10n.financeHubReportSummary,
                      description: l10n.financeHubReportSummarySub,
                      location: RouteName.financeReportSummary,
                    ),
                    _Entry(
                      icon: Icons.receipt_long_outlined,
                      label: l10n.financeHubReportStatement,
                      description: l10n.financeHubReportStatementSub,
                      location: RouteName.financeReportStatement,
                    ),
                    _Entry(
                      icon: Icons.account_balance_outlined,
                      label: l10n.financeHubReportAccountFlow,
                      description: l10n.financeHubReportAccountFlowSub,
                      location: RouteName.financeReportAccountFlow,
                    ),
                    const _Entry(
                      icon: Icons.savings_outlined,
                      label: '客户预收流水',
                      description: '查看预收款到账、抵扣、撤回及汇率差额',
                      location: RouteName.financeReportCustomerPrepayment,
                    ),
                    _Entry(
                      icon: Icons.handshake_outlined,
                      label: l10n.financeHubReportRecon,
                      description: l10n.financeHubReportReconSub,
                      location: RouteName.financeReportRecon,
                    ),
                    _Entry(
                      icon: Icons.calculate_outlined,
                      label: l10n.financeHubReportCost,
                      description: l10n.financeHubReportCostSub,
                      location: RouteName.financeReportCost,
                    ),
                    _Entry(
                      icon: Icons.menu_book_outlined,
                      label: l10n.financeHubReportGl,
                      description: l10n.financeHubReportGlSub,
                      location: RouteName.financeReportGl,
                    ),
                    // ADR-131 车间内料仓用量与结算 (塑料用量附表的数据来源)。
                    _Entry(
                      icon: Icons.scale_outlined,
                      label: l10n.workshopMaterialReports,
                      description: l10n.workshopMaterialReportsHubDesc,
                      location: RouteName.workshopMaterialReports,
                    ),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 一个分组：标题 + 卡片网格。
  Widget _section(
    BuildContext context,
    ThemeData theme,
    String title,
    List<_Entry> entries,
  ) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: UtenSpacing.s4,
              bottom: UtenSpacing.s8,
            ),
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          UtenResponsiveGrid(
            itemCount: entries.length,
            spacing: UtenSpacing.s12,
            columns: const UtenResponsiveColumns(compact: 2, medium: 3),
            itemBuilder: (context, i, _) => _EntryTile(entry: entries[i]),
          ),
        ],
      ),
    );
  }
}

/// 一个入口项（单据类型或报表）。
class _Entry {
  const _Entry({
    required this.icon,
    required this.label,
    required this.description,
    required this.location,
    this.badgeScope,
    this.badge,
  });

  final IconData icon;
  final String label;
  final String description;
  final String location;
  final BadgeScope? badgeScope;

  /// 右上角红色徽章：待办数或本人草稿数，都会进上层累加。
  ///
  /// 本页每张卡最多一个红徽章，故不再留行内 labelSuffix 槽——两个红点挤在
  /// 一张卡上读不懂，真要并存时才按「待办占 badge、草稿占 labelSuffix」拆。
  final Widget? badge;
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});
  final _Entry entry;

  @override
  Widget build(BuildContext context) {
    return UtenHubCard(
      icon: entry.icon,
      label: entry.label,
      description: entry.description,
      onTap: () => goFrom(context, entry.location),
      badgeScope: entry.badgeScope,
      badge: entry.badge,
    );
  }
}

/// 「资料草稿」面板顶部的钱流草稿下钻入口：5 类单据各一枚小按钮。
///
/// 财务模块顶栏红数含钱流草稿（服务端 financeDrafts 入口 + 本地填写草稿，
/// effective 按 ID 去重），而这些草稿此前只有各 /new 页的「草稿(N)」按钮可达；
/// 本组入口把用户从 hub 引到对应列表的草稿段（cfg.listLocation?status=draft，
/// 路由按 initialStatus 预选「草稿」段）。计数与 [UtenDraftsButton] 同源走
/// [draftCountsProvider]（服务端事实 + 本地草稿同一口径）；无该单据查看权限
/// 且计数为 0 时不显示该枚（跳过去也是空列表）。
/// 资产草稿（固定资产/长期待摊/政策）刻意不在此列——资产工作台自带「政策草稿」
/// Tab 与台账「草稿」计数筛选，hub 的「资产」卡即落点；把资产路由放进
/// [_FinanceHubPageState._draftScope] 会把业务草稿混进资料草稿分区。
class _MoneyFlowDraftEntries extends ConsumerWidget {
  const _MoneyFlowDraftEntries();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    final counts = ref.watch(draftCountsProvider);
    final configs = [
      for (final cfg in [
        for (final type in FinanceDocType.values) FinanceDocConfig.by(type),
      ])
        if (superAdmin ||
            counts.of(cfg.draftKind) > 0 ||
            permissions.contains(cfg.draftKind.viewPerm))
          cfg,
    ];
    if (configs.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s4,
        UtenSpacing.s12,
        UtenSpacing.s4,
        UtenSpacing.s12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '钱流草稿',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              for (final cfg in configs)
                UtenButton(
                  key: ValueKey(
                    'finance-hub-money-draft-${cfg.type.pathSegment}',
                  ),
                  type: UtenButtonType.tonal,
                  size: UtenButtonSize.small,
                  icon: cfg.icon,
                  onPressed: () => goFrom(
                    context,
                    '${cfg.listLocation}?status=$kDraftStatusQuery',
                  ),
                  child: UtenSegmentBadgeLabel(
                    label: '${cfg.shortLabel}草稿',
                    count: counts.of(cfg.draftKind),
                    countForm: UtenSegmentCountForm.actionable,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
