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
    void nativeAdvanceReversalDelegatesToTheActualAssetBankAndGlFacts() throws IOException {
        String payment = source("features/finance/payment/FinancePaymentService.java");
        String advance = source("features/finance/payables/SupplierPrepaymentService.java");
        String replay = Files.readString(Path.of("src/main/resources/db/migration/V1077__supplier_advance_statement_replay.sql"));
        assertThat(payment).doesNotContain("ledgerRepo.delete(ledger)")
                .contains("glPostingService.reverseActualBankPayment(p.getId(),reversedAt)")
                .contains("p.setStatus(STATUS_REVERSED);p.setReversedAt(reversedAt)")
                .contains("prepayments().reverse(p.getId(),p.getReversedAt())")
                .contains("reverseReconciliation(p.getId(),p.getReversedAt())");
        assertThat(advance).contains("v.source_type='PAYMENT_REV'")
                .contains("UPDATE finance_supplier_advances SET status='REVERSED',reversed_at=?");
        assertThat(replay).contains("PERFORM fn_assert_payment_v2_terminal(p_payment)")
                .contains("a.reversed_at IS DISTINCT FROM p.reversed_at")
                .contains("reversal_of_voucher_id=o.id")
                .contains("backward.account_id,backward.account_currency_id")
                .contains("EXCEPT ALL");
    }

    @Test
    void retainedLegacyDirectPaymentReplayStillRequiresItsDatedNegativeApProof() throws IOException {
        String payment = source("features/finance/payment/FinancePaymentService.java");
        String settlement = source("features/finance/payables/SupplierSettlementService.java");
        String proof=source("features/finance/SupplierAdvanceReplaySql.java");
        assertThat(payment).contains("prepayments().reverse(p.getId(),p.getReversedAt())");
        assertThat(payment).doesNotContain("ledgerRepo.delete(ledger)")
                .contains("if(p.getAmountAuthorityVersion()!=BANK_AUTHORITY_VERSION)throw new ApiException");
        assertThat(settlement).contains("SupplierAdvanceReplaySql.unreplayableReversal(\"payment\")");
        assertThat(proof).contains("legacy.source_doc_type='DIRECT_PAYMENT'")
                .contains("legacy.status=-1").contains("legacy.deleted_at IS NOT NULL")
                .contains("legacy.supplier_id=").contains("legacy.currency_id=")
                .contains("legacy.amount_original=-(").contains("legacy.amount_original_local=-(")
                .contains("NOT fn_finance_supplier_advance_replayable(")
                .contains("SELECT min(legacy.deleted_at)");
        assertThat(source("features/finance/report/FinanceCashEventSql.java"))
                .contains("SupplierAdvanceReplaySql.reversalDate(\"t\")");
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
