// 销售管理入口页（hub）—— 2026-09-24 模块三段式统一（docs/01-规划/
// 2026-09-24-模块三段式统一*.md）：
//  ① 任务中心：销售任务中心（订货进度/出货/零星/退货/报价/历史其它出货一站式查看）
//  ② 新建单据：报价/订货/出货/客户零星发货/退货 —— 直达各 /new 编辑页，
//     只对持新建权限者显示（浏览去任务中心），一律不挂徽章（用户口径）。
//     「历史其它出货单」是只读历史，不放新建区（浏览在任务中心）。
//  ③ 销售报表：明细/汇总 + 稀缺仲裁（不变）。
//
// 卡片统一用 UtenHubCard。计数口径（准则 14）：
//   · 任务中心卡：红 = SalesProgressBadge（财务驳回 + 可分批发货，salesAttention），
//     黄 = 在途订单数（salesOrderInFlight，ADR-100）。
//   · 新建区五张卡不挂数（2026-09-24 用户口径：新建入口不需要通知数量徽章；
//     草稿仍在新页「草稿(N)」按钮与任务中心草稿分段可见，模块累计照旧含草稿）。
// 权限来自 currentPermissionsProvider；路由用 SalesRoutePath 字面量。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_module_todo_chip.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_hub_card.dart';
import '../../../components/feedback/uten_in_progress_badge.dart';
import '../../../components/feedback/uten_module_progress_chip.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../config/sales_doc_config.dart';
import '../models/sales_doc.dart';
import '../widgets/sales_progress_badge.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../shared/badges/badge_registry.dart';

class SalesHubPage extends ConsumerWidget {
  const SalesHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final perms = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    // 返回 hub 即重拉徽章汇总（与采购/委外 hub 同款）：hub 是「办完事回来看
    // 还剩什么」的落点，各卡片红/黄徽章要跟上刚才办完的操作。
    ref.onPageResume(RouteName.sales, () => refreshBadges(ref));
    // 卡片显隐 = hub 目录登记的落点 + 路由守卫(与 /sales 入口守卫同源，ADR-109)。
    bool canOpen(String location) =>
        hubCardAllowed(RouteName.sales, location, perms, superAdmin);

    // 任务中心：销售任务中心（一站式查看全部销售单据与进度）。
    // 红徽章 = 财务驳回待修正 + 可分批发货待开单；黄徽章 = 在途订单数
    // (待排产 + 生产中 + 出货待财审 + 等仓库出货): 这批单还在生产/财务/仓库
    // 手上跑着, 销售现在不用动手, 与红徽章各答一个问题(ADR-100)。
    final taskEntries = <_Entry>[
      _Entry(
        icon: Icons.timeline_outlined,
        label: '销售任务中心',
        description: l10n.salesHubTaskOrderProgressSub,
        location: RouteName.salesTasks,
        badge: const SalesProgressBadge(),
        progressBadge: UtenInProgressBadge(
          count: ref.watch(
            badgeEntryInProgressProvider(BadgeEntry.salesOrderInFlight),
          ),
          showLabel: true,
        ),
      ),
    ].where((e) => canOpen(e.location)).toList();

    // 新建单据（2026-09-24 三段式）：直达各 /new 编辑页，creator-only
    //（无新建权限时隐藏，浏览去任务中心）；新建入口一律不挂徽章。
    final docEntries = <_Entry>[
      _Entry.fromCfg(SalesDocConfig.quote, l10n),
      _Entry.fromCfg(SalesDocConfig.order, l10n),
      _Entry.fromCfg(SalesDocConfig.shipment, l10n),
      _Entry.fromCfg(SalesDocConfig.customerShipment, l10n),
      _Entry.fromCfg(SalesDocConfig.returnDoc, l10n),
    ].where((e) => canOpen(e.location)).toList();

    final reportEntries = <_Entry>[
      _Entry(
        icon: Icons.list_alt_outlined,
        label: l10n.salesHubReportDetail,
        description: l10n.hubSubDetailPerItem,
        location: SalesRoutePath.reportDetail,
      ),
      _Entry(
        icon: Icons.bar_chart_outlined,
        label: l10n.salesHubReportSummary,
        description: l10n.hubSubSummaryPerDoc,
        location: SalesRoutePath.reportSummary,
      ),
    ].where((e) => canOpen(e.location)).toList();

    // 稀缺仲裁：主管查看货品预留占用、释放低优先级现货预留（让单）。仅持让单权限者可见。
    final scarcityEntries = <_Entry>[
      _Entry(
        icon: Icons.swap_horizontal_circle_outlined,
        label: l10n.salesHubScarcity,
        description: l10n.salesHubScarcitySub,
        location: RouteName.salesScarcity,
      ),
    ].where((e) => canOpen(e.location)).toList();

    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.salesHubTitle,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
        actions: [
          // 本模块「进行中」累计(黄, 在红药丸左边): 徽章汇总里 sales 容器的黄数
          // (服务端对本容器在办入口求和, ADR-108), 同样不在页面里手写加法。
          UtenModuleProgressChip(
            count: ref.watch(badgeModuleInProgressProvider(BadgeModule.sales)),
          ),
          // 本模块累计：徽章汇总里 sales 容器的红数(服务端对全部入口求和, 已含各单据卡
          // 草稿)，**页面里不要手写加法**——新增入口只改服务端徽章目录。
          UtenModuleTodoChip(
            count: ref.watch(badgeModuleTodoProvider(BadgeModule.sales)),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          // 轮询页不包选择区：销售进度徽章定时刷新（结构性闪现）与拖选并发有
          // CME 风险（准则 §3.4，用户口径：轮询页不包）。
          selectable: false,
          child: ListView(
            padding: EdgeInsets.only(
              top: UtenSpacing.s12,
              // 外壳 compact 已预留胶囊高度；medium+/桌面 Rail 不预留，取更大值。
              bottom: context.breakpoint.isCompact
                  ? UtenSpacing.s16
                  : UtenSpacing.s40,
            ),
            children: [
              if (taskEntries.isNotEmpty)
                _section(
                  context,
                  theme,
                  l10n.hubSectionTaskCenter,
                  taskEntries,
                ),
              if (taskEntries.isNotEmpty)
                const SizedBox(height: UtenSpacing.s16),
              if (docEntries.isNotEmpty)
                _section(context, theme, '新建单据', docEntries),
              if (docEntries.isNotEmpty && reportEntries.isNotEmpty)
                const SizedBox(height: UtenSpacing.s16),
              if (reportEntries.isNotEmpty)
                _section(context, theme, '报表中心', reportEntries),
              if (reportEntries.isNotEmpty && scarcityEntries.isNotEmpty)
                const SizedBox(height: UtenSpacing.s16),
              if (scarcityEntries.isNotEmpty)
                _section(
                  context,
                  theme,
                  l10n.salesHubSectionScarcity,
                  scarcityEntries,
                ),
            ],
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
            columns: const UtenResponsiveColumns(compact: 2, medium: 4),
            itemBuilder: (context, i, _) => _EntryTile(entry: entries[i]),
          ),
        ],
      ),
    );
  }
}

/// 一个入口项（单据类型或报表）。
class _Entry {
  _Entry({
    required this.icon,
    required this.label,
    required this.description,
    required this.location,
    this.badge,
    this.progressBadge,
  });

  /// 新建单据卡（2026-09-24 三段式）：只对能新建的人显示（外层 canOpen 过滤），
  /// 落点恒为 /new 编辑页（进卡即新建态，不显示历史）；新建入口一律不挂徽章。
  _Entry.fromCfg(SalesDocConfig cfg, AppLocalizations l10n)
    : icon = cfg.icon,
      label = '新建${_salesDocTitle(cfg.type, l10n)}',
      description = _salesDocSubtitle(cfg.type, l10n),
      location = SalesRoutePath.docNew(cfg.type.pathSegment),
      badge = null,
      progressBadge = null;

  final IconData icon;
  final String label;
  final String description;
  final String location;

  /// 右上角红色徽章（订单进度关注数 / 单据草稿数；null=无）。只放「需要我处理」的数。
  final Widget? badge;

  /// 右上角黄色「进行中」徽章(排在红徽章左边; null=该入口没有在办数)。
  /// 只放「已经在办、还没完、现在不用我动手」的数。
  final Widget? progressBadge;
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
      badge: entry.badge,
      progressBadge: entry.progressBadge,
    );
  }
}

// 单据卡标题/副标题本地化：config 仍是中文 const（列表/编辑页在用），
// hub 卡片经此映射按当前 locale 取标题 + 精简副标题。
String _salesDocTitle(SalesDocType t, AppLocalizations l10n) => switch (t) {
  SalesDocType.quote => l10n.salesHubDocQuote,
  SalesDocType.order => l10n.salesHubDocOrder,
  SalesDocType.shipment => l10n.salesHubDocShipment,
  SalesDocType.customerShipment => '客户零星发货',
  SalesDocType.otherShipment => l10n.salesHubDocOtherShipment,
  SalesDocType.returnDoc => l10n.salesHubDocReturn,
};

String _salesDocSubtitle(SalesDocType t, AppLocalizations l10n) => switch (t) {
  SalesDocType.quote => l10n.salesHubDocQuoteSub,
  SalesDocType.order => l10n.salesHubDocOrderSub,
  SalesDocType.shipment => l10n.salesHubDocShipmentSub,
  SalesDocType.customerShipment => '样品、赠送及没有订货单的客户发货，统一财审后出库',
  SalesDocType.otherShipment => l10n.salesHubDocOtherShipmentSub,
  SalesDocType.returnDoc => l10n.salesHubDocReturnSub,
};
