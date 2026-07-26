// MainShellPage - App 外壳 v4（响应式导航：compact 悬浮胶囊 / medium+ 左侧 Rail）
// 文档：docs/03-页面/App外壳.md
//
// 断点策略：
//   - compact（<600dp）：底部悬浮胶囊导航，4 项：工作台 / 通知 / 我的 / 设置，
//     布局与 v3 完全一致（overlay 悬浮、不占布局空间）
//   - medium+（≥600dp）：全高左侧 NavigationRail（surface 底 + 右侧发丝边框），
//     屏宽 ≥1280dp 时 extended 常驻标签，否则纯图标 + Tooltip；
//     内容区套 UtenContentContainer（maxWidth 1600 居中），超宽屏不再无限拉宽
//
// 主 Tab 承载（全断点一致）：
//   - 四个主 Tab 由内部 PageView 承载，支持左右跟手滑动（桌面端可鼠标拖拽），
//     四页 KeepAlive 保活；compact 下胶囊滑块高亮随 PageController.page 连续位置联动
//   - 业务子页面（工资条/报销/人事…）照常通过 go_router 进入，
//     外壳仅保留导航（高亮归属 Tab），不提供页间滑动
//   - 保活覆盖子页面：进入业务子页面（tabIndex==null）时 PageView 不从树移除，
//     仅以 Offstage 隐藏（仍 layout、保留 State 与滚动位置），子页面叠在上层；
//     故从任一 Tab 进子页再返回，各 Tab 滚动位置/状态不丢（不回顶部）。
//     见 _buildCompactShell / _buildRailShell 的 Stack+Offstage 结构。
//
// 路由同步：
//   - 滑动停稳 → onPageChanged → context.go(tab 路由)，URL 与页一致
//   - 深链 / 外部 go() 进 tab 路由 → build 检测页码不一致 → animateToPage

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_anim.dart';
import '../../dashboard/pages/dashboard_page.dart';
import '../../notice/pages/notice_list_page.dart';
import '../../notice/providers/notice_providers.dart';
import '../../profile/pages/profile_page.dart';
import '../../settings/pages/settings_page.dart';
import '../widgets/floating_capsule_nav_bar.dart';
import '../widgets/uten_side_nav_rail.dart';

class MainShellPage extends ConsumerStatefulWidget {
  const MainShellPage({super.key, required this.child});

  /// ShellRoute 传入的当前路由页面。
  /// 四个主 Tab 路由时忽略它（由内部 PageView 承载，保证滑动 + 状态保留）。
  final Widget child;

  @override
  ConsumerState<MainShellPage> createState() => _MainShellPageState();
}

class _MainShellPageState extends ConsumerState<MainShellPage> {
  /// 主 Tab 路由（顺序 = PageView 页序 = 导航项序）
  static const _tabLocations = <String>[
    RouteName.dashboard,
    RouteName.notice,
    RouteName.profile,
    RouteName.settings,
  ];

  /// Rail 展开（常驻标签）的最小屏宽
  static const double _railExtendedWidth = 1280;

  late final PageController _pageController;

  /// 连续页位置（喂胶囊滑块跟手）
  late final ValueNotifier<double> _position;

  @override
  void initState() {
    super.initState();
    // initState 不能用 dependOnInheritedWidget 读路由，
    // 先按 0 创建；首次 didChangeDependencies 若初始路由非 0 会立即跳正。
    _pageController = PageController();
    _position = ValueNotifier<double>(0);
    _pageController.addListener(_syncPositionFromController);
  }

  void _syncPositionFromController() {
    if (!_pageController.hasClients) return;
    final page = _pageController.page;
    if (page != null) _position.value = page;
  }

  @override
  void dispose() {
    _pageController.removeListener(_syncPositionFromController);
    _pageController.dispose();
    _position.dispose();
    super.dispose();
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

  void _onPageChanged(int index) {
    _position.value = index.toDouble();
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

  /// 四页保活 PageView（两个断点分支共用同一份定义）
  Widget _tabPageView() {
    return PageView(
      controller: _pageController,
      onPageChanged: _onPageChanged,
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
    final labels = <String>[
      l10n.navDashboard,
      l10n.navNotice,
      l10n.navProfile,
      l10n.navSettings,
    ];
    final unread = ref.watch(unreadNoticeCountProvider).valueOrNull ?? 0;

    final tabIndex = _exactTabIndex(location);

    if (tabIndex != null) {
      // 深链 / 点导航 / 权限重定向进入某 tab：
      // PageView 页码不一致时动画切到目标页（滑动停稳触发的 go() 到这里
      // 页码已一致，天然跳过，不会和手势打架）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pageController.hasClients) return;
        final current = _pageController.page?.round() ?? tabIndex;
        if (current != tabIndex) {
          _pageController.animateToPage(
            tabIndex,
            duration: UtenAnim.normal,
            curve: UtenAnim.standard,
          );
        }
      });
    } else {
      // 业务子页面：导航停在归属 tab（无滑动手势，位置固定）
      _position.value = _capsuleIndex(location).toDouble();
    }

    // compact 保留悬浮胶囊；medium+ 切换为左侧 Rail + 内容收敛
    if (context.breakpoint.isCompact) {
      return _buildCompactShell(tabIndex: tabIndex, labels: labels, unread: unread);
    }
    return _buildRailShell(
      tabIndex: tabIndex,
      location: location,
      labels: labels,
      unread: unread,
    );
  }

  /// compact 外壳：底部悬浮胶囊 overlay（与 v3 完全一致）
  Widget _buildCompactShell({
    required int? tabIndex,
    required List<String> labels,
    required int unread,
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
                    child: Offstage(
                      offstage: tabIndex == null,
                      child: _tabPageView(),
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
                badgeCounts: [0, unread, 0, 0],
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
              badgeCounts: [0, unread, 0, 0],
            ),
            Expanded(
              // 超宽屏内容居中收敛（maxWidth 1600 + 响应式 gutter）；
              // 主 Tab 页与业务子页面统一收敛，无胶囊因此不再需要底部预留
              child: UtenContentContainer(
                // PageView 常驻保活（同 compact 分支理由）：进业务子页面时仅 Offstage
                // 隐藏 PageView、子页面叠上层，切回 Tab 时滚动位置不丢
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Offstage(
                        offstage: tabIndex == null,
                        child: _tabPageView(),
                      ),
                    ),
                    if (tabIndex == null)
                      Positioned.fill(child: widget.child),
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
