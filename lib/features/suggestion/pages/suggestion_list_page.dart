// 建议箱列表页（含广场 + 我的，表格版）
//
// 2026-09-09 表格化改版：卡片网格 → MasterDataTableView（列对齐 + 分页）。
// 列：标题/类别/状态/提交人/提交时间/回复数/点赞数（原卡片字段全部保留）。
// 顶部 UtenSegmentedFilter 分段（建议广场/我的建议）保留在标题行；无多选
//（建议的处理动作是「官方回复+推进状态」，逐条语义，不做批量）；
// 行双击进详情；原卡片点赞能力移入行右键/长按菜单（点赞/取消点赞）。
// 2026-09-10 表头筛选：「状态」列筛选桶 = 四态（已提交/处理中/已采纳/未采纳），
// 选中后下推后端 status 参数并回第 1 页（非页内裁剪，与分段正交）。
// 分页走表格内置翻页条（provider 补 goToPage——同批次一工资条先例）。
// 空态/FAB 提交入口不变。
// 响应式：compact 下内容套 UtenContentContainer（medium+ 由 MainShell 统一收敛）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_list_create_action.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/ui/uten_notify.dart';
import '../../../core/utils/china_datetime.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/suggestion.dart';
import '../providers/suggestion_providers.dart';

class SuggestionListPage extends ConsumerWidget {
  const SuggestionListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(suggestionListProvider);
    final scope = ref.watch(suggestionScopeProvider);
    final statusFilter = ref.watch(suggestionStatusFilterProvider);
    final createAction = UtenListCreateAction(
      emptyIcon: Icons.lightbulb_outline_rounded,
      emptyMessage: scope == SuggestionScope.mine ? '您还没有提交过建议' : '暂无建议',
      emptyDescription: '提交第一条建议，与同事一起推动改进',
      emptyActionLabel: '提交建议',
      fabLabel: '提建议',
      actionIcon: Icons.edit_rounded,
      onPressed: () => context.go(RouteName.suggestionNew),
    );

    Widget body = RefreshIndicator(
      onRefresh: () => ref.read(suggestionListProvider.notifier).refresh(),
      child: list.when(
        loading: () => const UtenSkeletonList(itemCount: 6),
        error: (e, _) => UtenEmpty.error(
          message: '加载失败：$e',
          onAction: () => ref.invalidate(suggestionListProvider),
        ),
        data: (page) {
          final suggestions = page.items;
          // 空态保持「唯一提交入口」口径（提交按钮在空态里，不出 FAB）。
          if (suggestions.isEmpty) {
            return createAction.emptyState();
          }
          return MasterDataTableView<Suggestion>(
            key: const Key('suggestion-list-table'),
            columns: _columns,
            items: suggestions,
            facets: {'status': _statusFacets()},
            nullCounts: const {},
            filters: {'status': statusFilter?.name},
            onFilterChanged: (key, value) => _onFilterChanged(ref, key, value),
            // 双击行进入建议详情（保留现有路由与 push 语义）。
            onRowTap: (s) => context.push(RoutePath.suggestionDetail(s.id)),
            // 行右键/长按菜单：点赞/取消点赞（原卡片点赞按钮能力移入此处）。
            rowMenuBuilder: (s) => [
              UtenMenuItem(
                label: s.likedByMe ? '取消点赞' : '点赞',
                icon: s.likedByMe
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                onTap: () => _toggleLike(context, ref, s.id),
              ),
            ],
            emptyMessage: '暂无建议',
            currentPage: page.page,
            totalPages: page.totalPages,
            onPageChange: (p) =>
                ref.read(suggestionListProvider.notifier).goToPage(p),
          );
        },
      ),
    );
    // compact 下页面自带宽度收敛；medium+ 由 MainShell 的容器统一处理
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: '建议箱',
        showBackButton: true,
        centerWidget: UtenSegmentedFilter<SuggestionScope>(
          selected: scope,
          onChanged: (v) =>
              ref.read(suggestionScopeProvider.notifier).state = v,
          segments: const [
            UtenSegment(value: SuggestionScope.square, label: '建议广场'),
            UtenSegment(value: SuggestionScope.mine, label: '我的建议'),
          ],
        ),
      ),
      floatingActionButton: createAction.floatingActionButton(
        context,
        hasItems: list.valueOrNull?.items.isNotEmpty ?? false,
      ),
      body: body,
    );
  }
}

/// 「状态」列筛选桶：建议状态四态（value = 枚举名，与后端 status 一致）。
/// 桶不带计数（列表按页拉取，无全量计数口径）。
List<MasterFacetBucket> _statusFacets() => [
  for (final status in SuggestionStatus.values)
    MasterFacetBucket(value: status.name, count: 0, label: status.label),
];

/// 表头状态筛选 → 下推后端 status（provider 重建即回第 1 页）。
void _onFilterChanged(WidgetRef ref, String key, String? value) {
  if (key != 'status') return;
  ref.read(suggestionStatusFilterProvider.notifier).state = value == null
      ? null
      : SuggestionStatus.values.where((s) => s.name == value).firstOrNull;
}

Future<void> _toggleLike(BuildContext context, WidgetRef ref, String id) async {
  try {
    await ref.read(suggestionListProvider.notifier).toggleLike(id);
  } catch (error) {
    if (context.mounted) {
      UtenNotify.apiError(context, error, fallback: '点赞失败，请重试');
    }
  }
}

final List<MasterColumnDef<Suggestion>> _columns = [
  MasterColumnDef(key: 'title', label: '标题', width: 260, value: (s) => s.title),
  MasterColumnDef(
    key: 'category',
    label: '类别',
    width: 110,
    value: (s) => s.category.label,
  ),
  MasterColumnDef(
    key: 'status',
    label: '状态',
    width: 90,
    info: '表头筛选下推后端 status 参数（与「建议广场/我的建议」分段正交），选中即回第 1 页。',
    value: (s) => s.status.label,
  ),
  MasterColumnDef(
    key: 'submitter',
    label: '提交人',
    width: 130,
    info: '匿名建议由服务端按查看权限脱敏后展示。',
    value: (s) => s.displayName,
  ),
  MasterColumnDef(
    key: 'submittedAt',
    label: '提交时间',
    width: 110,
    value: (s) => _fmt(s.submittedAt),
  ),
  MasterColumnDef(
    key: 'replyCount',
    label: '回复数',
    width: 80,
    type: 'number',
    value: (s) => s.replyCount.toString(),
  ),
  MasterColumnDef(
    key: 'likes',
    label: '点赞数',
    width: 80,
    type: 'number',
    value: (s) => s.likes.toString(),
  ),
];

String _fmt(DateTime d) {
  final now = ChinaDateTime.now();
  final diff = now.difference(d);
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  return '${d.month}-${d.day.toString().padLeft(2, '0')}';
}
