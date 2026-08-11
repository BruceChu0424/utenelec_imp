package com.uten.imp.migration;

import org.flywaydb.core.api.resource.LoadableResource;
import org.flywaydb.core.internal.resolver.ChecksumCalculator;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.io.Reader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ReceivableSettlementMetadataMigrationContractTest {

    private static final Path V236 = Path.of(
            "src/main/resources/db/migration/V236__receivable_settlement_metadata.sql");
    private static final Path V238 = Path.of(
            "src/main/resources/db/migration/V238__receivable_settlement_post_apply_guard.sql");

    @Test
    void deployedV236ChecksumRemainsImmutable() {
        assertThat(ChecksumCalculator.calculate(resource(V236)))
                .isEqualTo(-2024018731);
    }

    @Test
    void receivableBreakdownKeepsUnverifiedForeignOriginalAmountsUnknown() throws Exception {
        String history = compact(V236);
        String guard = compact(V238);

        assertThat(history).contains("amount_received_original numeric(18,4)");
        assertThat(history).contains("amount_received_local numeric(18,4)");
        assertThat(history).contains("amount_write_off_original numeric(18,4)");
        assertThat(history).contains("amount_write_off_local numeric(18,4)");
        assertThat(history).contains("amount_balance_original numeric(18,4)");
        assertThat(history).contains("btrim(currency.name) = '人民币'");
        assertThat(history).contains("upper(btrim(currency.code)) in ('cny', 'rmb')");
        assertThat(history).contains("ledger.exchange_rate > 0");
        assertThat(history).doesNotContain("currency.status = '使用'");

        assertThat(guard).contains(
                "least( installed_on at time zone 'utc', installed_on at time zone 'asia/shanghai')",
                "ledger.created_at <= v236_conservative_cutoff",
                "ledger.updated_at <= v236_conservative_cutoff",
                "currency.updated_at <= v236_conservative_cutoff");
        assertThat(guard).contains("currency.status is distinct from '使用'");
        assertThat(guard).contains("coalesce(currency.is_deleted, false) = true");
        assertThat(guard).contains("ledger.exchange_rate is distinct from 1::numeric");
        assertThat(guard).contains("set amount_received_original = null");
        assertThat(guard).contains("from flyway_schema_history");
        assertThat(guard).doesNotContain("currency_id is null");
    }

    @Test
    void receiptLinesCarryCurrencyWriteOffApplicationAndBalanceSnapshots() throws Exception {
        String sql = compact(V236);

        assertThat(sql).contains("alter table finance_receipt_lines");
        assertThat(sql).contains("currency_id uuid references currencies(id)");
        assertThat(sql).contains("exchange_rate numeric(18,6)");
        assertThat(sql).contains("write_off_amount numeric(18,4)");
        assertThat(sql).contains("write_off_local numeric(18,4)");
        assertThat(sql).contains("applied_amount_local numeric(18,4)");
        assertThat(sql).contains("balance_before_original numeric(18,4)");
        assertThat(sql).contains("balance_after_original numeric(18,4)");
        assertThat(sql).contains("uq_finance_receipt_line_active_ledger");
    }

    @Test
    void salesOrderSourcesUseOnlyExplicitItemLinksAndShipmentAmounts() throws Exception {
        String sql = compact(V236);

        assertThat(sql).contains("create table ar_ap_source_refs");
        assertThat(sql).contains("unique (ledger_id, source_type, source_id)");
        assertThat(sql).contains("shipment_item.order_item_id is not null");
        assertThat(sql).contains("sum(shipment_item.amount_original)");
        assertThat(sql).contains("sum(shipment_item.amount_local)");
        assertThat(sql).doesNotContain("sales_order.bill_no = ledger.source_doc_no");
    }

    @Test
    void glLeavesAreIdempotentAndPreserveExistingAccounts() throws Exception {
        String history = compact(V236);
        String guard = compact(V238);

        assertThat(history).contains(
                "'sys-fin-bank-fee'",
                "'sys-fin-fx-gl'");
        assertThat(history).doesNotContain("existing.status = '使用'");

        assertThat(guard).contains("'手续费', 'expense'");
        assertThat(guard).contains("'汇兑损益', 'expense'");
        assertThat(guard).contains(
                "'sys-fin-bank-fee-v238'",
                "'sys-fin-fx-gl-v238'");
        assertThat(guard).contains("where style.path = '/043/'");
        assertThat(guard).contains("where not exists");
        assertThat(guard).contains(
                "existing.name = '手续费' and existing.status = '使用'",
                "existing.name = '汇兑损益' and existing.status = '使用'");
        assertThat(guard).doesNotContain("update payment_styles");
    }

    private static String compact(Path migration) throws Exception {
        return Files.readString(migration, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }

    private static LoadableResource resource(Path path) {
        Path absolute = path.toAbsolutePath().normalize();
        return new LoadableResource() {
            @Override
            public Reader read() {
                try {
                    return Files.newBufferedReader(absolute, StandardCharsets.UTF_8);
                } catch (IOException exception) {
                    throw new IllegalStateException("无法读取迁移: " + absolute, exception);
                }
            }

            @Override
            public String getAbsolutePath() {
                return absolute.toString();
            }

            @Override
            public String getAbsolutePathOnDisk() {
                return absolute.toString();
            }

            @Override
            public String getFilename() {
                return absolute.getFileName().toString();
            }

            @Override
            public String getRelativePath() {
                return V236.toString();
            }
        };
    }
}
