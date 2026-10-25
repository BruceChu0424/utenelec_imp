// 工资条列表页（表格版）
//
// 2026-09-09 表格化改版：卡片网格 → MasterDataTableView（列对齐 + 分页）。
// 列：期间/应发合计/扣除合计/实发合计/状态/发布时间（原卡片字段全部保留）。
// 标题下方独立分类行（未查看/已查看，已下载归已查看）；行双击进详情；
// 无多选（工资条对员工本人只有「看/下载」，没有可批量的状态动作）。分页走表格内置
// 翻页条（含跳页）。
// 2026-09-10 表头筛选：「状态」列筛选桶 = 分段可选状态集（已发布未查看/已查看/
// 已下载），在当前分类内细筛并回第 1 页（下推后端 status 参数，非页内裁剪）。
// 文档：docs/03-页面/工资条列表页.md
//
// 响应式：compact 由页面自套 UtenContentContainer（gutter 16）；
// medium+ 外壳（MainShellPage）已收敛内容区，页面不再重复套容器；
// 窄屏表格横向滚动即可。

import '../../../core/utils/china_datetime.dart';
import '../../../shared/models/retained_async_page.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../shared/formatters/money_display.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/payroll_slip.dart';
import '../providers/payroll_providers.dart';

class PayrollSlipListPage extends ConsumerStatefulWidget {
  const PayrollSlipListPage({super.key});

  @override
  ConsumerState<PayrollSlipListPage> createState() =>
      _PayrollSlipListPageState();
}

class _PayrollSlipListPageState extends ConsumerState<PayrollSlipListPage> {
  final _retainedPage = RetainedAsyncPage<PagedResult<PayrollSlip>>();

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(payrollFilterProvider);
    final paginationScope = (filter, ref.watch(masterDataSessionKeyProvider));
    final list = _retainedPage.resolve(
      paginationScope,
      ref.watch(payrollListProvider),
    );

    // compact 自套容器补 gutter；medium+ 外壳已收敛，避免双层 gutter
    Widget body = list.when(
      skipLoadingOnReload: true,
      skipError: true,
      loading: () => const UtenSkeletonList(itemCount: 8),
      error: (e, _) => UtenEmpty.error(
        message: humanErrorMessage(e) ?? '工资条列表没有加载出来，请稍后重试',
        actionLabel: '重试',
        onAction: () => ref.invalidate(payrollListProvider),
      ),
      data: (page) => RefreshIndicator(
        onRefresh: () => ref.read(payrollListProvider.notifier).refresh(),
        child: MasterDataTableView<PayrollSlip>(
          tableKey:
              'features.payroll.pages.payroll_slip_list_page.PayrollSlipListPage.build.1',
          key: const Key('payroll-slip-table'),
          paginationScope: paginationScope,
          loadingMore: list.isLoading,
          error: list.hasError
              ? (humanErrorMessage(list.error!) ?? '加载更多没有成功，请重试')
              : null,
          onRetry: () => ref.invalidate(payrollListProvider),
          columns: _columns,
          items: page.items,
          facets: {'status': _statusFacets(filter)},
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
    body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
          child: UtenFilterToolbar<PayrollFilter>(
            key: const Key('payroll-slip-categories'),
            selected: {filter.category},
            onSelectionChanged: (value) =>
                ref.read(payrollFilterProvider.notifier).state = value,
            segments: const [
              UtenFilterSegment(value: PayrollFilter.published, label: '未查看'),
              UtenFilterSegment(value: PayrollFilter.viewed, label: '已查看'),
            ],
          ),
        ),
        Expanded(child: body),
      ],
    );
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: const UtenAppBar(title: '工资条', showBackButton: true),
      body: body,
    );
  }
}

/// 「状态」列筛选桶：员工可见的三态（待发布对员工不可见，不进桶）。
/// value = PayrollSlipStatus 枚举名，桶不带计数（按页拉取，无全量计数口径）。
List<MasterFacetBucket> _statusFacets(PayrollFilter filter) => [
  for (final status
      in filter.category == PayrollFilter.published
          ? const [PayrollSlipStatus.published]
          : const [PayrollSlipStatus.viewed, PayrollSlipStatus.downloaded])
    MasterFacetBucket(value: status.name, count: 0, label: status.label),
];

/// 分类默认覆盖自身全部状态，只有表头的精确子状态显示为选中。
String? _statusFilterOf(PayrollFilter filter) => switch (filter) {
  PayrollFilter.published || PayrollFilter.viewed => null,
  PayrollFilter.viewedOnly => PayrollSlipStatus.viewed.name,
  PayrollFilter.downloaded => PayrollSlipStatus.downloaded.name,
};

/// 清除表头细筛仅回当前分类全集，始终保留一个可见分类。
void _onFilterChanged(WidgetRef ref, String key, String? value) {
  if (key != 'status') return;
  final next = switch (value) {
    null => ref.read(payrollFilterProvider).category,
    _ when value == PayrollSlipStatus.published.name => PayrollFilter.published,
    _ when value == PayrollSlipStatus.viewed.name => PayrollFilter.viewedOnly,
    _ when value == PayrollSlipStatus.downloaded.name =>
      PayrollFilter.downloaded,
    _ => ref.read(payrollFilterProvider),
  };
  ref.read(payrollFilterProvider.notifier).state = next;
}

final List<MasterColumnDef<PayrollSlip>> _columns = [
  MasterColumnDef(
    key: 'status',
    label: '状态',
    width: 72,
    info: '在当前分类内筛选具体状态；已下载归入已查看。清除筛选显示当前分类全部工资条。',
    value: (s) => s.status.label,
    // 2026-09-27 用户口径「表格状态列整格底色」；档位按 ADR-169 锚定
    // （与 PayrollSlipStatus.badgeType 同源）：待发布=灰 / 已发布=蓝（分发
    // 流转中）/ 已查看=青绿品牌档（员工已看过）/ 已下载=绿（领取完成）。
    cellColor: (context, s) => utenStatusBadgeCellColor(s.status.badgeType),
  ),
  MasterColumnDef(
    key: 'period',
    label: '期间',
    width: 110,
    value: (s) => s.periodLabelZh,
  ),
  // 工资恒人民币（2026-10-10 金额带单位口径：数值后自动带「元」）。
  MasterColumnDef(
    key: 'grossIncome',
    label: '应发合计',
    width: 140,
    type: 'money',
    aiSensitive: true,
    value: (s) =>
        financeLocalMoneyWithUnitSuffix(s.grossIncome.toStringAsFixed(2)),
  ),
  MasterColumnDef(
    key: 'totalDeduction',
    label: '扣除合计',
    width: 140,
    type: 'money',
    aiSensitive: true,
    value: (s) =>
        financeLocalMoneyWithUnitSuffix(s.totalDeduction.toStringAsFixed(2)),
  ),
  MasterColumnDef(
    key: 'netIncome',
    label: '实发合计',
    width: 150,
    type: 'money',
    aiSensitive: true,
    value: (s) =>
        financeLocalMoneyWithUnitSuffix(s.netIncome.toStringAsFixed(2)),
  ),
  MasterColumnDef(
    key: 'publishedAt',
    label: '发布时间',
    width: 160,
    type: 'date',
    value: (s) => s.publishedAt == null ? '—' : _formatTime(s.publishedAt!),
  ),
];

String _formatTime(DateTime t) => ChinaDateTime.formatDateTime(t);
