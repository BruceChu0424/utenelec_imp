// 检测列表页（Phase 4）
// 文档：docs/03-页面/检测列表页.md
//
// 响应式：搜索框统一为 UtenSearchBar（内置防抖 + 清除）；
// compact 自套 UtenContentContainer 收敛（medium+ 外壳已收敛）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/lab_test.dart';
import '../providers/lab_providers.dart';

class LabTestListPage extends ConsumerWidget {
  const LabTestListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(labFilterProvider);
    final listAsync = ref.watch(labListProvider);
    final theme = Theme.of(context);
    final isCompact = context.breakpoint.isCompact;

    // compact 下水平 gutter 由容器提供，页面自身水平 padding 让位
    final hPad = isCompact ? 0.0 : UtenSpacing.s16;

    Widget body = Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              hPad, UtenSpacing.s12, hPad, UtenSpacing.s8),
          child: UtenSearchBar(
            hint: '搜索样品编号 / 名称 / 项目',
            onChanged: (v) =>
                ref.read(labSearchProvider.notifier).state = v,
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(hPad, 0, hPad, UtenSpacing.s8),
          child: UtenSegmentedFilter<LabFilter>(
            selected: filter,
            onChanged: (v) =>
                ref.read(labFilterProvider.notifier).state = v,
            segments: const [
              UtenSegment(value: LabFilter.all, label: '全部'),
              UtenSegment(value: LabFilter.qualified, label: '合格'),
              UtenSegment(value: LabFilter.unqualified, label: '不合格'),
            ],
          ),
        ),
        Expanded(
          child: listAsync.when(
            loading: () => const UtenSkeletonList(itemCount: 6),
            error: (e, _) => UtenEmpty.error(
              message: '加载失败：$e',
              actionLabel: '重试',
              onAction: () => ref.invalidate(labListProvider),
            ),
            data: (list) {
              if (list.isEmpty) {
                return ListView(
                  children: const [
                    SizedBox(height: 80),
                    UtenEmpty(
                      icon: Icons.science_outlined,
                      message: '暂无检测记录',
                    ),
                  ],
                );
              }
              return SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.symmetric(
                    horizontal: hPad, vertical: UtenSpacing.s16),
                child: UtenResponsiveGrid(
                  itemCount: list.length,
                  itemBuilder: (context, i, _) => _LabCard(
                    test: list[i],
                    onTap: () => context.go('/lab/test/${list[i].id}'),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
    if (isCompact) body = UtenContentContainer(child: body);

    return Scaffold(
      appBar: const UtenAppBar(title: '检测记录', showBackButton: true),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/lab/test/upload'),
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: theme.colorScheme.onPrimary,
        icon: const Icon(Icons.upload_rounded),
        label: const Text('上传检测'),
      ),
      body: body,
    );
  }
}

class _LabCard extends StatelessWidget {
  const _LabCard({required this.test, required this.onTap});
  final LabTest test;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = test.qualified ? UtenColors.success : UtenColors.error;
    return UtenCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.science_outlined, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(test.sampleName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    Text(test.sampleCode,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              UtenStatusBadge(
                label: test.qualified ? '合格' : '不合格',
                type: test.qualified
                    ? UtenStatusBadgeType.success
                    : UtenStatusBadgeType.danger,
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                  child: Text('项目：${test.project}',
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis)),
              Text('${test.testDate.month}-${test.testDate.day}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }
}
