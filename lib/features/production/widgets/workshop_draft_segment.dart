import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../components/data_display/doc_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/drafts/form_draft_category.dart';
import '../../../shared/drafts/draft_workspace_sources.dart';
import '../models/production_daily_report.dart';

/// 我的车间任务「草稿」分段正文（2026-09-26 全站草稿口径）：本地表单草稿与
/// **我的服务端报工草稿**（GET /daily-reports?status=0，由页面侧统一拉取，与
/// 「生产中」待报扣减共用同一次读取）合并在同一张表里——参照
/// FormDraftCategoryTable 合并形态（production_daily_report_list_page 草稿段同款）。
///
/// 服务端行双击进生产日报详情页（审核 / 删除都在那边办）；本地行照旧
/// 「继续填写 / 删除草稿」。读取失败 fail-open：只显示本地草稿，并说明原因。
class WorkshopDraftSegment extends StatelessWidget {
  const WorkshopDraftSegment({
    super.key,
    required this.scope,
    required this.serverDrafts,
    required this.loading,
    required this.error,
    this.search = '',
  });

  /// 本地草稿范围（module=workshop，与分段计数同一 scope）。
  final FormDraftCategoryScope scope;

  /// 我的服务端报工草稿行（status=0）。
  final List<ProductionDailyReportListItem> serverDrafts;

  /// 服务端草稿是否仍在读取（读取中计数只数本地，fail-open 同口径）。
  final bool loading;

  /// 读取失败原因（非 null 时正文退回只显示本地草稿）。
  final String? error;

  /// 页级搜索关键字（与本地草稿共用同一搜索框）。
  final String search;

  List<MasterColumnDef<ProductionDailyReportListItem>> get _columns => [
    MasterColumnDef(
      key: 'draftCategory',
      label: '类别',
      width: 160,
      filterFromRows: true,
      value: (_) => '生产日报',
    ),
    MasterColumnDef(
      key: 'billNo',
      label: '单据号',
      width: 140,
      value: (it) => it.billNo,
    ),
    MasterColumnDef(
      key: 'billDate',
      label: '日期',
      width: 120,
      type: 'date',
      value: (it) {
        final date = it.billDate ?? '';
        return date.length >= 10 ? date.substring(0, 10) : date;
      },
    ),
    MasterColumnDef(
      key: 'workshop',
      label: '车间',
      width: 140,
      value: (it) => it.workshopName ?? '—',
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 100,
      value: (it) => productionStatusLabel(it.status),
      // 状态分类色铺整格底色，替代原格内胶囊（2026-09-27 用户口径）；
      // 本地草稿行由合并表统一显示「草稿」。
      cellColor: (context, it) =>
          udenStatusBadgeCellColor(context, docStatusBadgeType(it.status)),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final keyword = search.trim().toLowerCase();
    final visibleDrafts = keyword.isEmpty
        ? serverDrafts
        : serverDrafts.where((draft) {
            return _columns
                .map((column) => column.value(draft) ?? '')
                .join(' ')
                .toLowerCase()
                .contains(keyword);
          }).toList();
    final table = MasterDataTableView<ProductionDailyReportListItem>(
      tableKey:
          'features.production.widgets.workshop_draft_segment.WorkshopDraftSegment.build.1.v2',
      key: const Key('workshop-server-draft-table'),
      columns: _columns,
      items: visibleDrafts,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      // 服务端草稿行双击进日报详情（审核/删除在那边办）；本地草稿行由合并表
      // 接管成「继续填写」。
      onRowTap: (it) => context.push('/production/daily-reports/${it.id}'),
      canOpenRow: (it) => it.id.isNotEmpty,
      isLoading: loading,
      emptyMessage: '暂无草稿',
      // 草稿是暂态，防御性翻页封顶后不再提供分页（见页面 _loadDraftReportState；
      // currentPage/totalPages 默认即 1/1）。
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null)
          Padding(
            key: const Key('workshop-server-draft-error'),
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              error!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        Expanded(
          child: FormDraftCategoryTable<ProductionDailyReportListItem>(
            scope: scope,
            table: table,
            search: search,
            formalId: (it) => it.id,
            localValue: (draft, key) =>
                key == 'draftCategory' ? formDraftCategoryLabel(draft) : null,
            includeConfirmedWithoutRecord: true,
          ),
        ),
      ],
    );
  }
}
