import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_paged_read_provider.dart';
import '../../../shared/models/retained_async_page.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/hr_celebration_publication.dart';
import '../repositories/hr_task_repository.dart';

typedef _HistoryQuery = ({
  String type,
  String employeeName,
  String eventLabel,
  String publisher,
  String publishedAt,
  String? sort,
  bool ascending,
});

Map<String, String> _headerSearch(_HistoryQuery query) => {
  'search.employeeName': query.employeeName,
  'search.eventLabel': query.eventLabel,
  'search.publisher': query.publisher,
  'search.publishedAt': query.publishedAt,
};

final _historyReadProvider = Provider.autoDispose
    .family<
      ScopedPagedReadProviderLease<HrCelebrationPublication>,
      _HistoryQuery
    >(
      (ref, query) {
        ref.watch(masterDataSessionKeyProvider);
        ref.watch(hrTaskRepositoryProvider);
        return ScopedPagedReadProviderLease(ref, query: query);
      },
      dependencies: [
        exportContextEpochProvider,
        masterDataSessionKeyProvider,
        hrTaskRepositoryProvider,
      ],
    );

final _historyProvider = FutureProvider.autoDispose
    .family<
      PagedResult<HrCelebrationPublication>,
      ({_HistoryQuery headers, int page})
    >(
      (ref, query) {
        ref.watch(masterDataSessionKeyProvider);
        final repository = ref.watch(hrTaskRepositoryProvider);
        return ref
            .watch(_historyReadProvider(query.headers))
            .read(
              query.page,
              fetchPage: (page) => repository.celebrationHistory(
                type: query.headers.type,
                page: page,
                columnSearch: _headerSearch(query.headers),
                sort: query.headers.sort,
                ascending: query.headers.ascending,
              ),
            );
      },
      retry: pagedReadProviderRetry,
      dependencies: [
        masterDataSessionKeyProvider,
        hrTaskRepositoryProvider,
        _historyReadProvider,
      ],
    );

class HrCelebrationHistoryPanel extends ConsumerStatefulWidget {
  const HrCelebrationHistoryPanel({super.key, required this.type});
  final String type;
  @override
  ConsumerState<HrCelebrationHistoryPanel> createState() =>
      _HrCelebrationHistoryPanelState();
}

class _HrCelebrationHistoryPanelState
    extends ConsumerState<HrCelebrationHistoryPanel> {
  int _page = 1;
  final _filters = <String, String?>{};
  String? _sort;
  bool _ascending = true;
  _HistoryQuery get _query => (
    type: widget.type,
    employeeName: _filters['search.employeeName'] ?? '',
    eventLabel: _filters['search.eventLabel'] ?? '',
    publisher: _filters['search.publisher'] ?? '',
    publishedAt: _filters['search.publishedAt'] ?? '',
    sort: _sort,
    ascending: _ascending,
  );
  final _tableRows = MasterDataTableRowsController<HrCelebrationPublication>();
  final _retainedPage =
      RetainedAsyncPage<PagedResult<HrCelebrationPublication>>();
  @override
  void didUpdateWidget(HrCelebrationHistoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.type != widget.type) {
      _page = 1;
      _filters.clear();
      _sort = null;
      _ascending = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final headerScope = _query;
    final query = (headers: headerScope, page: _page);
    final readLease = ref.watch(_historyReadProvider(headerScope))
      ..bindView(context, currentQuery: () => _query);
    final result = _retainedPage.resolveFor(ref, (
      headerScope,
      retainedReaderEpoch(ref),
    ), _historyProvider(query));
    final page =
        result.value ??
        const PagedResult<HrCelebrationPublication>(
          items: [],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 0,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: MasterDataTableView<HrCelebrationPublication>(
            rowsController: _tableRows,
            expensiveRowMounts: false,
            key: const Key('hr-celebration-history-table'),
            tableKey: 'hr.celebration-publication-history',
            paginationScope: (headerScope, retainedReaderEpoch(ref)),
            columns: [
              MasterColumnDef(
                key: 'type',
                label: '类型',
                info: '当前类型由上方人事分类确定；生日祝福与入职周年使用各自的权限和历史范围。',
                columnSearchEnabled: false,
                width: 100,
                value: (row) => row.type == 'birthday' ? '生日祝福' : '入职周年',
              ),
              MasterColumnDef(
                key: 'employeeName',
                label: '员工',
                sortable: true,
                width: 130,
                value: (row) => row.employeeName,
              ),
              MasterColumnDef(
                key: 'eventLabel',
                label: '纪念事项',
                sortable: true,
                width: 160,
                value: (row) => row.eventLabel,
              ),
              MasterColumnDef(
                key: 'publishedAt',
                label: '发布时间',
                sortable: true,
                columnSearchEnabled: true,
                info:
                    '按真实发布时间回看已发布记录；历史未留存员工纪念日期快照。\n\n'
                    '按北京时间筛选发布年份、年月、日期或范围，例如 2026、2026-10 或 2026-10-01..2026-10-28。',
                width: 190,
                type: 'date',
                value: (row) => ChinaDateTime.formatIsoInstant(
                  row.publishedAt,
                  fallback: '—',
                ),
              ),
              MasterColumnDef(
                key: 'publisher',
                label: '发布人',
                sortable: true,
                width: 130,
                value: (row) => row.publisher,
              ),
            ],
            items: page.items,
            isLoading: result.isLoading && !result.hasValue,
            loadingMore: result.isLoading && result.hasValue,
            error: result.hasError
                ? humanErrorMessage(result.error!) ?? '发布记录未能加载，请重试'
                : null,
            onRetry: () {
              readLease.invalidate();
              ref.invalidate(_historyProvider(query));
            },
            facets: const {},
            nullCounts: const {},
            serverColumnSearch: true,
            filters: _filters,
            onFilterChanged: (key, value) {
              if (!key.startsWith('search.')) return;
              setState(() {
                if (value == null) {
                  _filters.remove(key);
                } else {
                  _filters[key] = value;
                }
                _page = 1;
              });
            },
            sortColumn: _sort,
            sortAscending: _ascending,
            onSortChange: (column, ascending) => setState(() {
              _sort = column;
              _ascending = ascending;
              _page = 1;
            }),
            rowKeyOf: (row) => row.id,
            onRowTap: (row) =>
                goFrom(context, RoutePath.noticeDetail(row.noticeId)),
            emptyMessage: '暂无已发布记录',
            currentPage: page.page,
            totalPages: page.totalPages,
            onPageChange: (value) => readLease.paginate(value, () async {
              setState(() => _page = value);
              final next = _historyProvider((
                headers: headerScope,
                page: value,
              ));
              ref.invalidate(next);
              await _retainedPage.waitFor(
                ref,
                next,
                () => ref.read(next.future),
              );
            }),
          ),
        ),
      ],
    );
  }
}
