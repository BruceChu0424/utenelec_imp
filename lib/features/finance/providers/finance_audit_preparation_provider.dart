import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/data_write_revision.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/paging/page_preparation_budget_provider.dart';
import '../../../shared/paging/page_preparation_coordinator.dart';
import '../../../shared/paging/prepared_page_read.dart';
import '../../../shared/paging/scoped_paged_read.dart';
import '../../../shared/paging/scoped_category_read.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/providers/retain_read_snapshot.dart';
import '../../../shared/sales_review/sales_order_review.dart';
import '../../../shared/sales_review/sales_order_review_repository.dart';
import '../../procurement_iqc_rejection/models/procurement_iqc_rejection.dart';
import '../../procurement_iqc_rejection/repositories/procurement_iqc_rejection_repository.dart';
import '../../sales/providers/sales_shipment_task_reads.dart';
import '../../sales/repositories/sales_repository.dart';
import '../../sales/models/sales_doc.dart';
import '../../warehouse/repositories/procurement_inbound_repository.dart';
import '../models/finance_procurement_workflow.dart';
import '../repositories/finance_procurement_workflow_repository.dart';
import '../models/sales_quote_finance_review.dart';
import '../repositories/sales_quote_finance_review_repository.dart';

/// The embedded and direct queue pages adopt the same complete query snapshots.
/// This store owns no claims, edits or business calculations.
class FinanceAuditPreparedPages {
  final confirmations = PreparedPageRead<SalesOrderFinancePendingItem>();
  final procurements = PreparedPageRead<FinanceProcurementApprovalTask>();
  final arrivals = PreparedPageRead<ProcurementArrivalException>();
  final iqc = PreparedPageRead<ProcurementIqcRejectionCase>();
  final quotes = PreparedPageRead<SalesQuoteFinanceListItem>();

  void dispose() {
    confirmations.dispose();
    procurements.dispose();
    arrivals.dispose();
    iqc.dispose();
    quotes.dispose();
  }
}

final financeAuditPreparedPagesProvider = Provider.autoDispose((ref) {
  ref.watch(exportContextEpochProvider);
  ref.watch(dataWriteRevisionProvider);
  retainReadSnapshot(ref);
  final pages = FinanceAuditPreparedPages();
  ref.onDispose(pages.dispose);
  return pages;
}, dependencies: [exportContextEpochProvider]);

Object financeConfirmationReadKey(
  Object repo, {
  int page = 1,
  int size = 20,
  bool? rejected,
  String? keyword,
  bool? changesOnly,
  bool confirmed = false,
  String? sort,
  String? order,
  String? billNo,
}) => [
  repo,
  page,
  size,
  rejected,
  keyword?.trim() ?? '',
  changesOnly,
  confirmed,
  sort,
  order,
  billNo?.trim(),
];

PagedReadSnapshot<SalesOrderFinancePendingItem, SalesOrderFinancePendingPage>
financeConfirmationSnapshot(SalesOrderFinancePendingPage response) =>
    PagedReadSnapshot(
      page: PagedResult(
        items: response.items,
        page: response.page,
        size: response.size,
        total: response.total,
        totalPages: response.totalPages,
      ),
      snapshot: response,
    );

Object financeProcurementReadKey(
  Object repo, {
  int page = 1,
  int size = 20,
  FinanceProcurementOrderType? orderType,
  String? keyword,
  String? sort,
  String? order,
  String? billNo,
  String status = 'PENDING',
}) => [
  repo,
  page,
  size,
  orderType,
  keyword?.trim() ?? '',
  sort,
  order,
  billNo?.trim(),
  status,
];

PagedReadSnapshot<
  FinanceProcurementApprovalTask,
  FinanceProcurementApprovalPage
>
financeProcurementSnapshot(FinanceProcurementApprovalPage response) =>
    PagedReadSnapshot(
      page: PagedResult(
        items: response.items,
        page: response.page,
        size: response.size,
        total: response.total,
        totalPages: response.totalPages,
      ),
      snapshot: response,
    );

Object financeArrivalReadKey(
  Object repo, {
  int page = 1,
  String status = 'PENDING_FINANCE',
}) => [repo, page, status];

Object financeIqcReadKey(Object repo, ProcurementIqcRejectionFilter filter) => [
  repo,
  filter.toQuery(),
];

Object financeQuoteReadKey(
  Object repo, {
  required SalesQuoteFinanceState state,
  int page = 1,
  int size = 20,
  String? keyword,
}) => [repo, state, page, size, keyword?.trim() ?? ''];

final financeQuotePreparationJobsProvider = Provider(
  (ref) {
    final pages = ref.watch(financeAuditPreparedPagesProvider);
    final repo = ref.watch(salesQuoteFinanceReviewRepositoryProvider);
    return <Future<void> Function()>[
      () => pages.quotes.prepare(
        financeQuoteReadKey(repo, state: SalesQuoteFinanceState.pending),
        () => repo.list(state: SalesQuoteFinanceState.pending),
      ),
      () async {
        await ref
            .read(scopedCategoryReadProvider)
            .read(
              query: [repo, 'quote-returned'],
              fetch: () =>
                  repo.list(state: SalesQuoteFinanceState.returned, size: 1),
            );
      },
      () => pages.quotes.prepare(
        financeQuoteReadKey(repo, state: SalesQuoteFinanceState.returned),
        () => repo.list(state: SalesQuoteFinanceState.returned),
      ),
    ];
  },
  dependencies: [
    financeAuditPreparedPagesProvider,
    salesQuoteFinanceReviewRepositoryProvider,
    scopedCategoryReadProvider,
  ],
);

/// Each group schedules only its current working queues. History and completed
/// states are intentionally absent; explicit table refreshes never adopt these.
List<Future<void> Function()> financeAuditPreparationJobs(
  Ref ref,
  String group,
) {
  final pages = ref.read(financeAuditPreparedPagesProvider);
  switch (group) {
    case 'salesConfirm':
      final repo = ref.watch(salesOrderFinanceConfirmationRepositoryProvider);
      return [
        () => pages.confirmations.prepare(
          financeConfirmationReadKey(repo, rejected: false),
          () async =>
              financeConfirmationSnapshot(await repo.pending(rejected: false)),
        ),
        () async {
          await ref
              .read(scopedCategoryReadProvider)
              .read(
                query: [repo, 'finance-rejected'],
                fetch: () => repo.pending(size: 1, rejected: true),
              );
        },
        for (final changesOnly in [false, true])
          () => pages.confirmations.prepare(
            financeConfirmationReadKey(
              repo,
              rejected: false,
              changesOnly: changesOnly,
            ),
            () async => financeConfirmationSnapshot(
              await repo.pending(rejected: false, changesOnly: changesOnly),
            ),
          ),
      ];
    case 'procurement':
      final repo = ref.watch(financeProcurementWorkflowRepositoryProvider);
      return [
        for (final status in ['PENDING', 'CLOSURE_PENDING'])
          for (final type in [
            null,
            FinanceProcurementOrderType.purchase,
            FinanceProcurementOrderType.subcontract,
          ])
            () => pages.procurements.prepare(
              financeProcurementReadKey(repo, orderType: type, status: status),
              () async => financeProcurementSnapshot(
                await repo.approvalTasks(orderType: type, status: status),
              ),
            ),
      ];
    case 'shipment':
      ref.watch(salesRepositoryProvider(SalesDocType.shipment));
      return [() => prepareFinanceShipmentFirstPage(ref)];
    case 'arrival':
      final repo = ref.watch(procurementInboundRepositoryProvider);
      return [
        () => pages.arrivals.prepare(
          financeArrivalReadKey(repo),
          () => repo.financeTasks(status: 'PENDING_FINANCE'),
        ),
      ];
    case 'iqc':
      final repo = ref.watch(procurementIqcRejectionRepositoryProvider);
      return [
        () async {
          await ref
              .read(scopedCategoryReadProvider)
              .read(
                query: [
                  repo,
                  'iqc-counts',
                  const ProcurementIqcRejectionFilter().toQuery(
                    includePaging: false,
                    includeStatus: false,
                    includeOrdering: false,
                  ),
                ],
                fetch: () => repo.counts(const ProcurementIqcRejectionFilter()),
              );
        },
        for (final status in [
          'ACTIVE',
          'PENDING_RETURN',
          'RETURN_RECORDED',
          'FINANCE_EXCEPTION',
        ])
          () {
            final filter = ProcurementIqcRejectionFilter(status: status);
            return pages.iqc.prepare(
              financeIqcReadKey(repo, filter),
              () => repo.list(filter),
            );
          },
      ];
    default:
      return const [];
  }
}

final financeAuditPreparationJobsProvider =
    Provider.family<List<Future<void> Function()>, String>(
      (ref, group) {
        ref.watch(exportContextEpochProvider);
        ref.watch(dataWriteRevisionProvider);
        ref.watch(financeAuditPreparedPagesProvider);
        return financeAuditPreparationJobs(ref, group);
      },
      dependencies: [
        exportContextEpochProvider,
        financeAuditPreparedPagesProvider,
        salesOrderFinanceConfirmationRepositoryProvider,
        financeProcurementWorkflowRepositoryProvider,
        procurementInboundRepositoryProvider,
        procurementIqcRejectionRepositoryProvider,
        salesRepositoryProvider,
        scopedCategoryReadProvider,
      ],
    );

final financeAuditPreparationProvider = Provider((ref) {
  final coordinator = PagePreparationCoordinator(
    budget: ref.read(pagePreparationBudgetProvider),
  );
  final retire = pagePreparationRetirementCallback(ref, coordinator.retire);

  ref.listen(exportContextEpochProvider, (_, _) => retire());
  ref.listen(dataWriteRevisionProvider, (_, _) => retire());
  ref.onDispose(coordinator.dispose);
  return coordinator;
}, dependencies: [exportContextEpochProvider]);
