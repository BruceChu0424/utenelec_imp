// DashboardPage - 工作台首页（v3 - 响应式收敛 + 区块化视觉）
// 文档：docs/03-页面/工作台首页.md
//
// 设计原则(默认使用 frontend-design，遵循项目组件与主题规范)：
// - 信息密度高，去花哨装饰
// - 区块靠卡片分隔，不靠渐变
// - 颜色克制：中性为主，品牌色仅点缀
//
// 「今日概览」「待办事项」来自服务端聚合接口；服务端按当前用户权限、部门与数据范围裁剪，
// 前端仅负责展示，不以隐藏组件替代数据授权。
//
// 响应式：
// - 所有断点：滚动视口占满页面可用宽度，UtenContentContainer 在滚动内容内
//   提供 16 / 24 的边距，页面竖条保持贴外侧。MainShell 在工作台路由不先扣边距。
// - compact 底部避让悬浮胶囊；medium+ 无胶囊，底部留白 32。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_user_avatar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../features/admin/widgets/impersonation_actions.dart';
import '../../../features/notice/widgets/celebration_popup_gate.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/session_provider.dart';
import '../widgets/dashboard_overview_sections.dart';
import '../widgets/workbench_module_area.dart';

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final theme = Theme.of(context);

    final name = session.user?.name ?? 'Uten';
    final isCompact = context.breakpoint.isCompact;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPageHeader(context, ref, theme, name),
        const SizedBox(height: UtenSpacing.s24),
        const DashboardOverviewSections(),
        const SizedBox(height: UtenSpacing.s24),
        // 功能模块区：原侧边栏全部分组迁入，按权限点显隐（各组可折叠）
        const WorkbenchModuleArea(),
        // 登录庆典弹窗触发器（每日一次；不可见）。
        const CelebrationPopupGate(),
      ],
    );

    return Scaffold(
      // 底部留白：compact 96（悬浮胶囊 overlay 不占布局，滚到底可越过胶囊）；
      // medium+ 无胶囊，32 即可
      body: SingleChildScrollView(
        key: const Key('dashboard-page-scroll'),
        // 底部留白：compact 按胶囊遮挡高度避让（含系统手势条 + 呼吸量）；
        // medium+ 无胶囊，32 即可
        padding: EdgeInsets.only(
          top: UtenSpacing.s20,
          bottom: isCompact
              ? UtenSpacing.s16 + UtenCapsuleNavScope.occlusionOf(context)
              : UtenSpacing.s32,
        ),
        // selectable:false：工作台模块徽章轮询（结构性闪现）与拖选并发有 CME
        // 风险（准则 §3.4，用户口径：轮询页不包；当年全局事故的触发源即徽章轮询）。
        child: UtenContentContainer(
          key: const Key('dashboard-page-content'),
          selectable: false,
          child: content,
        ),
      ),
    );
  }

  /// 页头：问候语 20px w600 为主层级，日期 13px 三级文字为辅。
  /// 仅超级管理员（且非模拟中）显示「切换人」入口（模拟时由横幅接管切换/退出）。
  Widget _buildPageHeader(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    String name,
  ) {
    final isSuperAdmin = ref.watch(isSuperAdminProvider);
    final identity = Row(
      children: [
        UtenUserAvatar(name: name),
        const SizedBox(width: UtenSpacing.s12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '你好，$name',
                style: theme.textTheme.headlineMedium?.copyWith(
                  height: 1.3,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                _formatDate(ChinaDateTime.today()),
                style: theme.textTheme.bodySmall?.copyWith(
                  height: 1.3,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final actions = Wrap(
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s8,
      alignment: WrapAlignment.end,
      children: [
        UtenButton(
          key: const ValueKey('dashboard-software-downloads'),
          type: UtenButtonType.secondary,
          size: UtenButtonSize.small,
          icon: Icons.download_rounded,
          onPressed: () => pushPage(context, RouteName.softwareDownloads),
          child: const Text('软件下载'),
        ),
        if (isSuperAdmin)
          UtenActionButton(
            type: UtenActionButtonType.secondary,
            size: UtenActionButtonSize.small,
            icon: Icons.swap_horiz_rounded,
            label: Text(AppLocalizations.of(context).impersonationSwitchPerson),
            onAction: () => openSwitchPerson(context, ref),
          ),
      ],
    );
    return LayoutBuilder(
      builder: (context, bounds) {
        if (bounds.maxWidth < 640 ||
            MediaQuery.textScalerOf(context).scale(16) > 24) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              identity,
              const SizedBox(height: UtenSpacing.s12),
              actions,
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: identity),
            const SizedBox(width: UtenSpacing.s16),
            actions,
          ],
        );
      },
    );
  }

  String _formatDate(DateTime date) {
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final w = weekdays[date.weekday - 1];
    return '${date.year}年${date.month}月${date.day}日 · $w';
  }
}
