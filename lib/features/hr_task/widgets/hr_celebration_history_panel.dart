import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_paged_read_provider.dart';
import '../../../shared/models/retained_async_page.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/hr_celebration_publication.dart';
import '../repositories/hr_task_repository.dart';

final _historyReadProvider = Provider.autoDispose
    .family<ScopedPagedReadProviderLease<HrCelebrationPublication>, String>(
      (ref, type) {
        ref.watch(masterDataSessionKeyProvider);
        ref.watch(hrTaskRepositoryProvider);
        return ScopedPagedReadProviderLease(ref, query: (type,));
      },
      dependencies: [
        exportContextEpochProvider,
        masterDataSessionKeyProvider,
        hrTaskRepositoryProvider,
      ],
    );

final _historyProvider = FutureProvider.autoDispose
    .family<PagedResult<HrCelebrationPublication>, ({String type, int page})>(
      (ref, query) {
        ref.watch(masterDataSessionKeyProvider);
        final repository = ref.watch(hrTaskRepositoryProvider);
        return ref
            .watch(_historyReadProvider(query.type))
            .read(
              query.page,
              fetchPage: (page) =>
                  repository.celebrationHistory(type: query.type, page: page),
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
  final _tableRows = MasterDataTableRowsController<HrCelebrationPublication>();
  final _retainedPage =
      RetainedAsyncPage<PagedResult<HrCelebrationPublication>>();
  @override
  Widget build(BuildContext context) {
    final query = (type: widget.type, page: _page);
    final readLease = ref.watch(_historyReadProvider(widget.type))
      ..bindView(context, currentQuery: () => (widget.type,));
    final result = _retainedPage.resolveFor(ref, (
      widget.type,
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
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('按真实发布时间回看已发布记录；历史未留存员工纪念日期快照。'),
        ),
        Expanded(
          child: MasterDataTableView<HrCelebrationPublication>(
            rowsController: _tableRows,
            expensiveRowMounts: false,
            key: const Key('hr-celebration-history-table'),
            tableKey: 'hr.celebration-publication-history',
            paginationScope: (widget.type, retainedReaderEpoch(ref)),
            columns: [
              MasterColumnDef(
                key: 'type',
                label: '类型',
                width: 100,
                value: (row) => row.type == 'birthday' ? '生日祝福' : '入职周年',
              ),
              MasterColumnDef(
                key: 'employeeName',
                label: '员工',
                width: 130,
                value: (row) => row.employeeName,
              ),
              MasterColumnDef(
                key: 'eventLabel',
                label: '纪念事项',
                width: 160,
                value: (row) => row.eventLabel,
              ),
              MasterColumnDef(
                key: 'publishedAt',
                label: '发布时间',
                width: 190,
                type: 'date',
                value: (row) => row.publishedAt,
              ),
              MasterColumnDef(
                key: 'publisher',
                label: '发布人',
                width: 130,
                value: (row) => row.publisher,
              ),
            ],
            items: page.items,
            isLoading: result.isLoading && !result.hasValue,
            loadingMore: result.isLoading && result.hasValue,
            error: result.hasError ? '发布记录未能加载，请重试' : null,
            onRetry: () {
              readLease.invalidate();
              ref.invalidate(_historyProvider(query));
            },
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            rowKeyOf: (row) => row.id,
            onRowTap: (row) =>
                goFrom(context, RoutePath.noticeDetail(row.noticeId)),
            emptyMessage: '暂无已发布记录',
            currentPage: page.page,
            totalPages: page.totalPages,
            onPageChange: (value) => readLease.paginate(value, () async {
              setState(() => _page = value);
              final next = _historyProvider((type: widget.type, page: value));
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
