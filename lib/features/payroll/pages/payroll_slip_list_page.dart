// 工资条列表页（表格版）
//
// 2026-09-09 表格化改版：卡片网格 → MasterDataTableView（列对齐 + 分页）。
// 列：期间/应发合计/扣除合计/实发合计/状态/发布时间（原卡片字段全部保留）。
// 顶部 UtenSegmentedFilter 分段（全部/未查看/已查看/已下载）保留；行双击进详情；
// 无多选（工资条对员工本人只有「看/下载」，没有可批量的状态动作）。分页走表格内置
// 翻页条（含跳页）。
// 2026-09-10 表头筛选：「状态」列筛选桶 = 分段可选状态集（已发布未查看/已查看/
// 已下载），选中即切到对应分段并回第 1 页（下推后端 status 参数，非页内裁剪）。
// 文档：docs/03-页面/工资条列表页.md
//
// 响应式：compact 由页面自套 UtenContentContainer（gutter 16）；
// medium+ 外壳（MainShellPage）已收敛内容区，页面不再重复套容器；
// 窄屏表格横向滚动即可。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/payroll_slip.dart';
import '../providers/payroll_providers.dart';

class PayrollSlipListPage extends ConsumerWidget {
  const PayrollSlipListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(payrollListProvider);
    final filter = ref.watch(payrollFilterProvider);

    // compact 自套容器补 gutter；medium+ 外壳已收敛，避免双层 gutter
    Widget body = list.when(
      loading: () => const UtenSkeletonList(itemCount: 8),
      error: (e, _) => UtenEmpty.error(
        message: '加载失败：$e',
        actionLabel: '重试',
        onAction: () => ref.invalidate(payrollListProvider),
      ),
      data: (page) => RefreshIndicator(
        onRefresh: () => ref.read(payrollListProvider.notifier).refresh(),
        child: MasterDataTableView<PayrollSlip>(
          key: const Key('payroll-slip-table'),
          columns: _columns,
          items: page.items,
          facets: {'status': _statusFacets()},
          nullCounts: const {},
          filters: {'status': _statusFilterOf(filter)},
          onFilterChanged: (key, value) => _onFilterChanged(ref, key, value),
          // 双击行进入工资条详情。
          onRowTap: (slip) =>
              context.push(RoutePath.payrollSlipDetail(slip.id)),
          emptyMessage: '此状态下暂无工资条',
          currentPage: page.page,
          totalPages: page.totalPages,
          onPageChange: (p) =>
              ref.read(payrollListProvider.notifier).goToPage(p),
        ),
      ),
    );
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: '工资条',
        showBackButton: true,
        centerWidget: UtenSegmentedFilter<PayrollFilter>(
          selected: filter,
          onChanged: (v) => ref.read(payrollFilterProvider.notifier).state = v,
          segments: const [
            UtenSegment(value: PayrollFilter.all, label: '全部'),
            UtenSegment(value: PayrollFilter.published, label: '未查看'),
            UtenSegment(value: PayrollFilter.viewed, label: '已查看'),
            UtenSegment(value: PayrollFilter.downloaded, label: '已下载'),
          ],
        ),
      ),
      body: body,
    );
  }
}

/// 「状态」列筛选桶：员工可见的三态（待发布对员工不可见，不进桶）。
/// value = PayrollSlipStatus 枚举名，桶不带计数（按页拉取，无全量计数口径）。
List<MasterFacetBucket> _statusFacets() => [
  for (final status in const [
    PayrollSlipStatus.published,
    PayrollSlipStatus.viewed,
    PayrollSlipStatus.downloaded,
  ])
    MasterFacetBucket(value: status.name, count: 0, label: status.label),
];

/// 分段 → 表头选中值（全部段不选中任何状态）。
String? _statusFilterOf(PayrollFilter filter) => switch (filter) {
  PayrollFilter.all => null,
  PayrollFilter.published => PayrollSlipStatus.published.name,
  PayrollFilter.viewed => PayrollSlipStatus.viewed.name,
  PayrollFilter.downloaded => PayrollSlipStatus.downloaded.name,
};

/// 表头状态筛选 → 切到对应分段（provider 重建即回第 1 页）。
void _onFilterChanged(WidgetRef ref, String key, String? value) {
  if (key != 'status') return;
  final next = switch (value) {
    null => PayrollFilter.all,
    _ when value == PayrollSlipStatus.published.name => PayrollFilter.published,
    _ when value == PayrollSlipStatus.viewed.name => PayrollFilter.viewed,
    _ when value == PayrollSlipStatus.downloaded.name =>
      PayrollFilter.downloaded,
    _ => PayrollFilter.all,
  };
  ref.read(payrollFilterProvider.notifier).state = next;
}

final List<MasterColumnDef<PayrollSlip>> _columns = [
  MasterColumnDef(
    key: 'period',
    label: '期间',
    width: 110,
    value: (s) => s.periodLabelZh,
  ),
  MasterColumnDef(
    key: 'grossIncome',
    label: '应发合计',
    width: 110,
    type: 'money',
    value: (s) => s.grossIncome.toStringAsFixed(2),
  ),
  MasterColumnDef(
    key: 'totalDeduction',
    label: '扣除合计',
    width: 110,
    type: 'money',
    value: (s) => s.totalDeduction.toStringAsFixed(2),
  ),
  MasterColumnDef(
    key: 'netIncome',
    label: '实发合计',
    width: 120,
    type: 'money',
    value: (s) => s.netIncome.toStringAsFixed(2),
  ),
  MasterColumnDef(
    key: 'status',
    label: '状态',
    width: 100,
    info: '表头筛选与顶部分段同一口径：选中状态即切到对应分段并回第 1 页。',
    value: (s) => s.status.label,
  ),
  MasterColumnDef(
    key: 'publishedAt',
    label: '发布时间',
    width: 160,
    type: 'date',
    value: (s) => s.publishedAt == null ? '—' : _formatTime(s.publishedAt!),
  ),
];

String _formatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
