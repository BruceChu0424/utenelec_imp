package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SupplierSettlementAndClaimContractTest {
    private static final Path MIGRATIONS=Path.of("src/main/resources/db/migration");
    private static final Path MAIN=Path.of("src/main/java/com/uten/imp/features/finance/payables");

    @Test
    void monthlySnapshotIsDatedImmutableAndServerTermControlled() throws Exception{
        String schema=Files.readString(MIGRATIONS.resolve("V360__supplier_settlement_batches.sql"));
        String guards=Files.readString(MIGRATIONS.resolve("V362__supplier_settlement_snapshot_guards.sql"));
        String service=Files.readString(MAIN.resolve("SupplierSettlementService.java"));
        assertThat(schema).contains("opening_balance_local","period_posted_local",
                "period_paid_local","period_offset_local","closing_balance_local","snapshot_hash");
        assertThat(guards).contains("financial snapshot is immutable",
                "snapshot lines are append-only","header totals do not equal frozen lines");
        assertThat(service)
                .contains("paymentTermService.resolveDueDate",
                "COALESCE(payment.reversed_at, payment.updated_at)",
                " AT TIME ZONE 'Asia/Shanghai')::DATE",
                "(reversed_at AT TIME ZONE 'Asia/Shanghai')::DATE",
                "(ledger.deleted_at AT TIME ZONE 'Asia/Shanghai')::DATE",
                "reversal_date","offset_event",
                "当前月份尚未结束");
        assertThat(service).doesNotContain("updated_at::DATE", "reversed_at::DATE", "deleted_at::DATE");
    }

    @Test
    void cashClaimIsAReceivableAndNotGenericNegativeAp() throws Exception{
        String schema=Files.readString(
                MIGRATIONS.resolve("V373__supplier_claim_receivables_and_cash_receipts.sql"));
        String service=Files.readString(MAIN.resolve("SubcontractLossClaimService.java"));
        String gl=Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/gl/GlPostingService.java"));
        assertThat(schema).contains("supplier_claim_receivables",
                "SUPPLIER_CLAIM_RECEIVABLE","SUBCONTRACT_LOSS_RECOVERY");
        assertThat(service).contains("createCashClaimReceivable","fulfillCashCompensation",
                "supplier_claim_cash_receipts","finance_reconciliations");
        assertThat(gl).contains("SUPPLIER_CLAIM_RECEIVABLE","SUPPLIER_CLAIM_CASH",
                "SUBCONTRACT_LOSS_RECOVERY");
    }

    @Test
    void offsetsHaveStableSequenceRateAndPeriodGuards() throws Exception{
        String sequence=Files.readString(
                MIGRATIONS.resolve("V368__supplier_claim_offset_stable_sequences.sql"));
        String rate=Files.readString(MIGRATIONS.resolve("V372__supplier_offset_rate_guard.sql"));
        String service=Files.readString(MAIN.resolve("SupplierOpenItemOffsetService.java"));
        String command=Files.readString(MAIN.resolve("SupplierOffsetCommandService.java"));
        String closedGuard=Files.readString(MAIN.resolve("SupplierClosedPeriodGuard.java"));
        assertThat(sequence).contains("resolution_seq","line_sequence");
        assertThat(rate).contains("source_rate=target_rate");
        assertThat(service).contains("ORDER BY line_sequence DESC","offset_batch_id,line_sequence");
        assertThat(service)
                .contains("\"PREPAYMENT\".equals(source.kind())")
                .contains("专用资产科目、应用、退款和总账链完成前禁止自动核销")
                .doesNotContain("source.kind().equals(\"PREPAYMENT\")");
        assertThat(command).contains("禁止倒填或预填财务期间",
                "closedPeriodGuard.requireOpen","lockAutoProjectionPeriod");
        assertThat(closedGuard).contains("supplier_settlement_batches");
    }
}
