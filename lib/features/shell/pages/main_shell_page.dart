// MainShellPage - App 外壳 v4（响应式导航：compact 悬浮胶囊 / medium+ 左侧 Rail）
// 文档：docs/03-页面/App外壳.md
//
// 断点策略：
//   - compact（<600dp）：底部悬浮胶囊导航，4 项：工作台 / 通知 / 我的 / 设置，
//     布局与 v3 完全一致（overlay 悬浮、不占布局空间）；工作台挂总待办角标
//     （= 各模块卡角标之和，workbenchTotalTodoCountProvider）、通知挂未读角标
//   - medium+（≥600dp）：全高左侧 NavigationRail（surface 底 + 右侧发丝边框），
//     屏宽 ≥1280dp 时 extended 常驻标签，否则纯图标 + Tooltip；
//     内容区套 UtenContentContainer（maxWidth 1600 居中），超宽屏不再无限拉宽
//
// 主 Tab 承载（全断点一致）：
//   - 四个主 Tab 由 UtenSlidingTabView 承载：离散方向滑动转场（当前页左移 / 新页右进），
//     不经过中间页（替代旧 PageView，消除工作台→设置 等跨多页点击时中间页闪烁）；
//     四页常驻保活（Offstage 隐藏仍 layout、保留 State 与滚动位置）；
//     compact 触屏支持横滑切相邻 Tab，胶囊滑块高亮随转场 lerp 联动
//   - 业务子页面（工资条/报销/人事…）照常通过 go_router 进入，
//     外壳仅保留导航（高亮归属 Tab），不提供页间滑动
//   - 保活覆盖子页面：进入业务子页面（tabIndex==null）时滑动容器不从树移除，
//     仅以 Offstage 隐藏（仍 layout、保留 State 与滚动位置），子页面叠在上层；
//     故从任一 Tab 进子页再返回，各 Tab 滚动位置/状态不丢（不回顶部）。
//     见 _buildCompactShell / _buildRailShell 的 Stack+Offstage 结构。
//
// 路由同步：
//   - 横滑切相邻 Tab 落定 → onChanged → context.go(tab 路由)，URL 与页一致
//   - 点击导航 / 深链 / 外部 go() 进 tab 路由 → build 检测 index 变化 →
//     UtenSlidingTabView 内部 post-frame 启动转场

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../dashboard/pages/dashboard_page.dart';
import '../../dashboard/providers/dashboard_overview_provider.dart';
import '../../dashboard/providers/workbench_refresh.dart';
import '../../dashboard/widgets/module_badge_sum.dart'
    show workbenchTotalTodoCountProvider;
import '../../notice/pages/notice_list_page.dart';
import '../../notice/providers/notice_providers.dart';
import '../../profile/pages/profile_page.dart';
import '../../settings/pages/settings_page.dart';
import '../widgets/floating_capsule_nav_bar.dart';
import '../widgets/idle_timeout_guard.dart';
import '../widgets/uten_side_nav_rail.dart';
import '../widgets/uten_sliding_tab_view.dart';

class MainShellPage extends ConsumerStatefulWidget {
  const MainShellPage({super.key, required this.child});

  /// ShellRoute 传入的当前路由页面。
  /// 四个主 Tab 路由时忽略它（由内部 PageView 承载，保证滑动 + 状态保留）。
  final Widget child;

  @override
  ConsumerState<MainShellPage> createState() => _MainShellPageState();
}

class _MainShellPageState extends ConsumerState<MainShellPage>
    with WidgetsBindingObserver {
  /// 主 Tab 路由（顺序 = PageView 页序 = 导航项序）
  static const _tabLocations = <String>[
    RouteName.dashboard,
    RouteName.notice,
    RouteName.profile,
    RouteName.settings,
  ];

  /// Rail 展开（常驻标签）的最小屏宽
  static const double _railExtendedWidth = 1280;

  /// 连续页位置（喂胶囊滑块跟手；由 UtenSlidingTabView 随转场 lerp 驱动）
  late final ValueNotifier<double> _position;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _position = ValueNotifier<double>(0);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _position.dispose();
    super.dispose();
  }

  /// 切回前台（resumed）时立即刷新通知未读数 + 列表，弥补无推送通道时
  /// 「后台收到新通知、回到前台看不到、要等下次 60s 轮询」的延迟。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(unreadNoticeCountProvider.notifier).refresh();
      ref.invalidate(noticeListProvider);
    }
  }

  /// location 恰好是某主 Tab 根路由 → 返回页码；否则 null（业务子页面）
  int? _exactTabIndex(String location) {
    for (var i = 0; i < _tabLocations.length; i++) {
      if (location == _tabLocations[i]) return i;
    }
    return null;
  }

  /// 导航高亮归属：前缀匹配（如 /notice/123 → 通知 tab），无匹配回 0
  int _capsuleIndex(String location) {
    for (var i = 0; i < _tabLocations.length; i++) {
      final root = _tabLocations[i];
      if (location == root || location.startsWith('$root/')) return i;
    }
    return 0;
  }

  /// 横滑切到相邻 Tab 落定：同步路由（与点击导航终点一致）。
  void _onTabChanged(int index) {
    final location = GoRouterState.of(context).matchedLocation;
    if (location != _tabLocations[index]) {
      context.go(_tabLocations[index]);
    }
  }

  void _onTabTap(int index) {
    // 收起键盘/焦点，避免切页后键盘残留
    FocusManager.instance.primaryFocus?.unfocus();
    final location = GoRouterState.of(context).matchedLocation;
    if (location == _tabLocations[index]) return;
    context.go(_tabLocations[index]);
  }

  /// 四页保活 + 离散滑动转场的 Tab 容器（两个断点分支共用同一份定义）。
  /// 替代旧 PageView：避免点击非相邻 Tab 时「滚过」中间页闪烁
  /// （工作台→我的 不再闪过通知；工作台→设置 不再闪过中间两页）。
  Widget _slidingTabs({required int? tabIndex}) {
    return UtenSlidingTabView(
      index: tabIndex,
      position: _position,
      onChanged: _onTabChanged,
      // compact：横滑手势 + 左右滑动转场（手机 PageView 直觉）；
      // rail 桌面：都关——点 Tab 即时切换，避免大屏整页横移突兀，也不开横滑手势。
      swipeEnabled: context.breakpoint.isCompact,
      animated: context.breakpoint.isCompact,
      children: const [
        _KeepAlivePage(child: DashboardPage()),
        _KeepAlivePage(child: NoticeListPage()),
        _KeepAlivePage(child: ProfilePage()),
        _KeepAlivePage(child: SettingsPage()),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final location = GoRouterState.of(context).matchedLocation;

    // 「返回即刷新」：任何导航落定（子页面返回 / 切 Tab / 系统返回手势）后，
    // 立即重拉全部全局角标（生产/采购/研发/访客/HR/通知未读），不等 60s 轮询；
    // 落点是工作台时再 invalidate 今日概览（重聚合），是通知 Tab 时再刷通知列表。
    // 于是「审计中心返回工作台」「销售订货单走完流程返回」等场景回到的页面
    // 立即显示最新待办与角标。
    ref.listen(pageResumeProvider, (prev, next) {
      if (prev == null || prev.location.isEmpty) return; // App 启动首次落定
      if (next.location == prev.location) return; // 原地通知（路径未变）
      // 全局角标只在落点=工作台时刷新：这些角标仅工作台/导航栏可见，落到 list/detail
      // 等页面时刷新全是不可见计数，且会抢返回转场帧造成卡顿。各模块 hub 自带
      // ref.onPageResume 刷各自计数；通知徽标由 60s 轮询/切前台/新通知到达联动保持。
      if (next.location == RouteName.dashboard) {
        refreshGlobalBadges(ref);
        ref.invalidate(dashboardOverviewProvider);
      } else if (next.location == RouteName.notice) {
        ref.invalidate(noticeListProvider);
      }
    });

    // 「通知→角标联动」：未读数上升（有新通知到达，如「采购财务通过」）即刷新全部
    // 模块角标，用户无需手动刷新整页。prev 守卫避免 App 首次加载误触发。
    // 联动粒度为「任意新通知→全刷」（成本仅为几次廉价 count 查询，无副作用）。
    ref.listen(unreadNoticeCountProvider, (prev, next) {
      if (prev != null && next > prev) refreshGlobalBadges(ref);
    });

    final labels = <String>[
      l10n.navDashboard,
      l10n.navNotice,
      l10n.navProfile,
      l10n.navSettings,
    ];
    final unread = ref.watch(unreadNoticeCountProvider);
    // 导航「工作台」Tab 角标 = 全部模块卡角标之和（与卡片同源；常驻 watch 使
    // autoDispose 计数源保持存活，更新时机同 refreshGlobalBadges/60s 轮询）。
    final workbenchTodos = ref.watch(workbenchTotalTodoCountProvider);

    final tabIndex = _exactTabIndex(location);

    // 业务子页面（tabIndex==null）：滑动容器被 Offstage 隐藏、不驱动 _position，
    // 故在此把胶囊高亮固定到归属 Tab。主 Tab 页则交由 UtenSlidingTabView 驱动 _position。
    if (tabIndex == null) {
      _position.value = _capsuleIndex(location).toDouble();
    }

    // compact 保留悬浮胶囊；medium+ 切换为左侧 Rail + 内容收敛
    final shell = context.breakpoint.isCompact
        ? _buildCompactShell(
            tabIndex: tabIndex,
            labels: labels,
            unread: unread,
            workbenchTodos: workbenchTodos,
          )
        : _buildRailShell(
            tabIndex: tabIndex,
            location: location,
            labels: labels,
            unread: unread,
            workbenchTodos: workbenchTodos,
          );
    // 包空闲超时守卫：监听全局活动续期，超时弹窗 + 登出（仅已登录区生效）
    return IdleTimeoutGuard(child: shell);
  }

  /// compact 外壳：底部悬浮胶囊 overlay（与 v3 完全一致）
  Widget _buildCompactShell({
    required int? tabIndex,
    required List<String> labels,
    required int unread,
    required int workbenchTodos,
  }) {
    return Scaffold(
      // 胶囊导航不随键盘升起；body 不被键盘压缩
      resizeToAvoidBottomInset: false,
      // 悬浮 overlay 布局：胶囊不占布局空间。
      // - 主 Tab 页：内容全高直通屏底，胶囊浮在玻璃层上，
      //   各 Tab 页自带底部留白（滚到底内容可越过胶囊）
      // - 业务子页面：不少页面自带底部固定操作栏（bottomNavigationBar），
      //   底部预留胶囊高度，保证按钮/列表最后一项不被遮挡
      body: Stack(
        children: [
          Positioned.fill(
            child: SafeArea(
              bottom: false,
              // PageView 常驻保活：进业务子页面（tabIndex==null）时不移除 PageView，
              // 仅以 Offstage 隐藏；否则各 Tab 的滚动位置/状态随 PageView 卸载而丢失
              // （从 Tab 进子页再返回会回到顶部）。Offstage 仍 layout 子树、保留 element
              // 与 State，PageView 的 widget 树位置恒定，切回 Tab 原样恢复位置。
              child: Stack(
                children: [
                  Positioned.fill(
                    child: TickerMode(
                      // 业务子页保留四个主 Tab 的 State/滚动位置，但不可继续
                      // 驱动骨架屏、轮播等 ticker，避免隐藏页面占用渲染帧。
                      enabled: tabIndex != null,
                      child: Offstage(
                        offstage: tabIndex == null,
                        child: _slidingTabs(tabIndex: tabIndex),
                      ),
                    ),
                  ),
                  if (tabIndex == null)
                    Positioned.fill(
                      child: Padding(
                        padding: EdgeInsets.only(bottom: _navReserve(context)),
                        child: widget.child,
                      ),
                    ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 6,
            child: SafeArea(
              top: false,
              child: FloatingCapsuleNavBar(
                position: _position,
                onTap: _onTabTap,
                labels: labels,
                badgeCounts: [workbenchTodos, unread, 0, 0],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// medium+ 外壳：左侧 Rail + UtenContentContainer 收敛内容区
  Widget _buildRailShell({
    required int? tabIndex,
    required String location,
    required List<String> labels,
    required int unread,
    required int workbenchTodos,
  }) {
    return Scaffold(
      // 与 compact 保持一致：键盘弹起不压缩页面（桌面端影响可忽略）
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        bottom: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenSideNavRail(
              extended: context.screenWidth >= _railExtendedWidth,
              // 主 Tab 页高亮当前页；业务子页面高亮归属 tab（前缀匹配）
              selectedIndex: tabIndex ?? _capsuleIndex(location),
              onTap: _onTabTap,
              labels: labels,
              badgeCounts: [workbenchTodos, unread, 0, 0],
            ),
            Expanded(
              // 超宽屏内容居中收敛（maxWidth 1600 + 响应式 gutter）；
              // 主 Tab 页与业务子页面统一收敛，无胶囊因此不再需要底部预留
              child: UtenContentContainer(
                // ⚠️ selectable:false 必须保留：此容器包住所有 medium+ 路由页（含常驻
                // 保活的工作台/通知 Tab），若包 SelectionArea 等于变相全局包裹——
                // 徽章/通知轮询的动态重建与拖选并发会触发框架 CME（准则 §3.4、
                // 2026-07-30 事故）。页面级选择由各页面自己的容器/局部包裹承担。
                selectable: false,
                // PageView 常驻保活（同 compact 分支理由）：进业务子页面时仅 Offstage
                // 隐藏 PageView、子页面叠上层，切回 Tab 时滚动位置不丢
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: TickerMode(
                        // 与 compact 分支一致：保活不等于继续耗帧。
                        enabled: tabIndex != null,
                        child: Offstage(
                          offstage: tabIndex == null,
                          child: _slidingTabs(tabIndex: tabIndex),
                        ),
                      ),
                    ),
                    if (tabIndex == null) Positioned.fill(child: widget.child),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 业务子页面底部预留高度 = 胶囊高 + 上下间距 + 系统手势条高度（仅 compact）
  static double _navReserve(BuildContext context) {
    return FloatingCapsuleNavBar.navHeight +
        10 +
        MediaQuery.paddingOf(context).bottom;
  }
}

/// PageView 子页保活：滑过的页常驻，滚动位置 / 页面状态不丢。
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
