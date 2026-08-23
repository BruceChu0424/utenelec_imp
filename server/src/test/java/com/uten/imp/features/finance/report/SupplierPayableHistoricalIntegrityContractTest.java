package com.uten.imp.features.finance.report;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SupplierPayableHistoricalIntegrityContractTest {

    @Test
    void periodReportExplainsNewLossClaimCreditsInItsDisplayedMovementColumns() throws IOException {
        String report = source("features/finance/report/FinanceReportService.java");
        String payableSummary = between(report,
                "private ReportTableResponse payableSummaryAuthorized",
                "private ReportTableResponse executeRawPaged");

        assertThat(payableSummary)
                .as("SUBCONTRACT_LOSS_OFFSET changes ending AP and must appear in a period movement column")
                .contains("source_doc_type='SUBCONTRACT_LOSS_OFFSET'");
    }

    @Test
    void historicalAsOfDoesNotDependOnRowsThatThePostingServicePhysicallyDeletes() throws IOException {
        String report = source("features/finance/report/FinanceReportService.java");
        String payableSummary = between(report,
                "private ReportTableResponse payableSummaryAuthorized",
                "private ReportTableResponse executeRawPaged");
        String arApPosting = source("features/finance/arap/ArApLedgerServiceImpl.java");

        boolean reportReadsOnlyCurrentLedger = payableSummary.contains("FROM ar_ap_ledger")
                && !payableSummary.contains("ar_ap_ledger_events")
                && !payableSummary.contains("audit_log");
        boolean postingReversalPhysicallyDeletes = arApPosting.contains("repo.deleteAll(rows)")
                || arApPosting.contains("repo.delete(ledger)");

        assertThat(reportReadsOnlyCurrentLedger && postingReversalPhysicallyDeletes)
                .as("an as-of report cannot reconstruct postings that were later physically deleted")
                .isFalse();
    }

    @Test
    void reversedDirectSupplierAdvanceRetainsItsDatedLedgerEvent() throws IOException {
        String payment = source("features/finance/payment/FinancePaymentService.java");
        String settlement = source("features/finance/payables/SupplierSettlementService.java");

        assertThat(payment)
                .doesNotContain("ledgerRepo.delete(ledger)")
                .contains("ledger.setStatus((short) -1)")
                .contains("ledger.setDeleted(true)")
                .contains("ledger.setDeletedAt(reversedAt)");
        assertThat(settlement)
                .contains("ledger.source_doc_type='DIRECT_PAYMENT'")
                .contains("ledger.status=-1")
                .contains("ledger.deleted_at IS NOT NULL");
    }

    private static String between(String source, String start, String end) {
        int from = source.indexOf(start);
        int to = source.indexOf(end, from + start.length());
        assertThat(from).as("start marker %s", start).isGreaterThanOrEqualTo(0);
        assertThat(to).as("end marker %s", end).isGreaterThan(from);
        return source.substring(from, to);
    }

    private static String source(String relative) throws IOException {
        return Files.readString(Path.of("src/main/java/com/uten/imp", relative));
    }
}
