// DashboardPage - 工作台首页（v3 - 响应式收敛 + 区块化视觉）
// 文档：docs/03-页面/工作台首页.md
//
// 设计原则（ui-ux-pro-max）：
// - 信息密度高，去花哨装饰
// - 区块靠卡片分隔，不靠渐变
// - 颜色克制：中性为主，品牌色仅点缀
//
// 「今日概览」「待办事项」两段的数据聚合尚未接后端（原为前端 mock），
// 暂以「功能规划接入中」占位承接，避免假数据误导；待后端聚合接口接入后再回填。
//
// 响应式：
// - compact：页面自带 UtenContentContainer（水平 gutter 16），
//   底部留白 96，滚到底内容可越过悬浮胶囊导航
// - medium+：外壳（MainShellPage）已提供 UtenContentContainer
//   （maxWidth 1600 居中 + gutter 24/32），页面不再叠加，避免双重 gutter；
//   无胶囊遮挡，底部留白 32

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/data_display/uten_user_avatar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
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
        _buildPageHeader(theme, name),
        const SizedBox(height: UtenSpacing.s24),
        const DashboardOverviewSections(),
        const SizedBox(height: UtenSpacing.s24),
        // 功能模块区：原侧边栏全部分组迁入，按权限点显隐（各组可折叠）
        const WorkbenchModuleArea(),
      ],
    );

    return Scaffold(
      // 底部留白：compact 96（悬浮胶囊 overlay 不占布局，滚到底可越过胶囊）；
      // medium+ 无胶囊，32 即可
      body: SingleChildScrollView(
        padding: EdgeInsets.only(
          top: UtenSpacing.s20,
          bottom: isCompact ? 96 : UtenSpacing.s32,
        ),
        // compact 由页面自行收敛宽度；medium+ 外壳已套 UtenContentContainer，
        // 再套一层会叠加 gutter，故按断点取舍
        child: isCompact ? UtenContentContainer(child: content) : content,
      ),
    );
  }

  /// 页头：问候语 20px w600 为主层级，日期 13px 三级文字为辅
  Widget _buildPageHeader(ThemeData theme, String name) {
    return Row(
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
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                _formatDate(ChinaDateTime.today()),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.3,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime date) {
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final w = weekdays[date.weekday - 1];
    return '${date.year}年${date.month}月${date.day}日 · $w';
  }
}
