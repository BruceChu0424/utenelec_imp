import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_paged_read.dart';
import '../../../shared/sales_review/sales_order_review.dart';
import '../models/finance_procurement_workflow.dart';

// Selected complete-query response adapters only. No speculative provider/cache.
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
      rebuildSnapshot: response.withPage,
    );

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
      rebuildSnapshot: response.withPage,
    );
