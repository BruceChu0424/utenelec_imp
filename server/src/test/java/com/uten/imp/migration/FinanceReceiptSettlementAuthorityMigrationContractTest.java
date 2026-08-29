package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;

class FinanceReceiptSettlementAuthorityMigrationContractTest {

    @Test
    void v407SeparatesGrossSettlementAccountPostingAndFeesWithoutRewritingHistory()
            throws IOException {
        String sql=resource("db/migration/V407__finance_receipt_settlement_authority.sql");

        assertThat(sql)
                .contains("settlement_authority_version SMALLINT NOT NULL DEFAULT 0")
                .contains("account_amount NUMERIC(18,4)")
                .contains("account_amount_local NUMERIC(18,4)")
                .contains("bank_fee_account_amount NUMERIC(18,4)")
                .contains("other_fee_account_amount NUMERIC(18,4)")
                .contains("'DEDUCTED_FROM_PROCEEDS','PAID_SEPARATELY'")
                .contains("fee_bearer VARCHAR(24)")
                .contains("fee_bearer='COMPANY'")
                .contains("gl_account_style_id UUID")
                .contains("gl_counter_style_id UUID")
                .contains("CREATE OR REPLACE VIEW v_receipt_expected_gl_entries")
                .contains("exchange_rate_effective_at TIMESTAMPTZ")
                .contains("bank_booked_at TIMESTAMPTZ")
                .contains("settlement_agent_supplier_id UUID")
                .contains("settlement_rate_quote_direction='BASE_PER_SETTLEMENT'")
                .contains("DROP CONSTRAINT finance_receipts_prepayment_money_chk")
                .doesNotContain("VALIDATE CONSTRAINT finance_receipts_prepayment_money_chk")
                .contains("CREATE OR REPLACE FUNCTION fn_guard_finance_receipt_money_fact")
                .contains("CREATE CONSTRAINT TRIGGER trg_finance_receipt_v1_lines")
                .contains("RECEIPT_REV")
                .contains("receipt_gl_voucher_immutable_guard")
                .contains("CREATE OR REPLACE VIEW v_receipt_gl_integrity")
                .contains("CREATE OR REPLACE VIEW v_receipt_v0_gl_reconciliation")
                .contains("finance_receipts_v1_lifecycle_chk")
                .contains("EXCEPT ALL")
                .contains("receipt_gl_voucher_expected_entries_guard")
                .contains("receipt_gl_terminal_link_guard")
                .contains("new receipt GL voucher must start as draft status 0")
                .contains("BEFORE INSERT OR UPDATE OR DELETE ON gl_entries")
                .contains("write_off_amount")
                .contains("V1 receipts require zero")
                .doesNotContain("UPDATE finance_receipts\nSET settlement_authority_version=1");
    }

    @Test
    void v408MakesAccountFlowsAppendOnlyAndExposesCacheDrift() throws IOException {
        String sql=resource("db/migration/V408__append_only_account_flow_and_integrity.sql");

        assertThat(sql)
                .contains("posting_seq BIGINT GENERATED ALWAYS AS IDENTITY")
                .contains("entry_kind IN ('POSTING','REVERSAL','ADJUSTMENT')")
                .contains("reversal_of_id UUID")
                .contains("'RECEIPT_FEE'")
                .contains("'SUPPLIER_CLAIM_RECEIPT'")
                .contains("finance_reconciliations_append_only_guard")
                .contains("uq_finance_reconciliation_active_source_account_kind")
                .contains("idx_frec_account_date_stable")
                .contains("CREATE OR REPLACE VIEW v_account_balance_integrity")
                .contains("CREATE OR REPLACE VIEW v_receipt_flow_integrity")
                .contains("CREATE OR REPLACE FUNCTION fn_assert_v1_receipt_flow_terminal")
                .contains("v_authority_version<>1 OR v_status NOT IN(1,-1)")
                .contains("CONSTRAINT='receipt_flow_terminal_guard'")
                .contains("CREATE CONSTRAINT TRIGGER trg_guard_receipt_flow_terminal_from_receipt")
                .contains("CREATE CONSTRAINT TRIGGER trg_guard_receipt_flow_terminal_from_flow")
                .contains("NEW.source_doc_type IN('RECEIPT','RECEIPT_FEE')")
                .contains("DEFERRABLE INITIALLY DEFERRED")
                .contains("CREATE TABLE account_flow_monthly_summaries")
                .contains("CREATE OR REPLACE FUNCTION fn_rebuild_account_flow_monthly_summaries")
                .contains("CREATE OR REPLACE VIEW v_account_flow_monthly_integrity")
                .contains("CREATE OR REPLACE FUNCTION fn_assert_account_flow_monthly_integrity")
                .contains("trg_upsert_account_flow_monthly_summary")
                .contains("AT TIME ZONE 'Asia/Shanghai'")
                .contains("account.balance_current-")
                .contains("accounts_historical_money_authority_guard");
    }

    @Test
    void v416AddsForwardOnlyReviewQueuesWithoutGuessingHistoricalMoney() throws IOException {
        String sql=resource("db/migration/V416__finance_migration_exception_queues.sql");

        assertThat(sql)
                .contains("CREATE OR REPLACE VIEW v_receipt_v0_settlement_exceptions")
                .contains("V0_BANK_AND_CHANNEL_EVIDENCE_UNAVAILABLE")
                .contains("V0_FEE_OR_WRITEOFF_AMBIGUOUS")
                .contains("finance_receipts_v1_external_evidence_chk")
                .contains("amount_local=ROUND(amount_original*exchange_rate,4)")
                .contains("approver_id IS NOT NULL AND approver_id<>maker_id")
                .contains("CREATE OR REPLACE VIEW v_account_flow_migration_exceptions")
                .contains("FOREIGN_LOCAL_SNAPSHOT_UNPROVEN")
                .contains("native_balance_blocking")
                .contains("finance_reconciliations_local_amount_guard")
                .contains("finance_reconciliations_source_identity_guard")
                .contains("finance_reconciliations_base_amount_guard")
                .doesNotContain("UPDATE finance_receipts")
                .doesNotContain("UPDATE finance_reconciliations")
                .doesNotContain("DELETE FROM finance_reconciliations");
    }

    private static String resource(String path) throws IOException {
        try(var stream=FinanceReceiptSettlementAuthorityMigrationContractTest.class
                .getClassLoader().getResourceAsStream(path)){
            assertThat(stream).as(path).isNotNull();
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }
    }
}
