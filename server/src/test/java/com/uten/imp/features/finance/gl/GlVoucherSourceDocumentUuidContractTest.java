package com.uten.imp.features.finance.gl;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

class GlVoucherSourceDocumentUuidContractTest {

    @Test
    void v266BackfillsOnlyFromUnanimousEntriesAndProtectsFutureAutoVouchers() throws IOException {
        String sql = source("src/main/resources/db/migration/"
                + "V266__gl_voucher_source_document_uuid.sql");
        String normalized = canonical(sql);

        assertThat(normalized)
                .contains("ALTER TABLE gl_vouchers ADD COLUMN source_doc_id UUID")
                .contains("JOIN gl_entries entry ON entry.voucher_id = voucher.id")
                .contains("COUNT(entry.source_doc_id) = COUNT(*)")
                .contains("COUNT(DISTINCT entry.source_doc_id) = 1")
                .contains("HAVING COUNT(*) = 1")
                .contains("CREATE UNIQUE INDEX ux_gl_vouchers_active_auto_source_doc")
                .contains("ON gl_vouchers(source_type, source_doc_id)")
                .contains("source = 'AUTO'")
                .contains("source_doc_id IS NOT NULL")
                .contains("gl_vouchers_regenerated_source_doc_required_chk")
                .contains(") NOT VALID");

        assertThat(normalized)
                .doesNotContain("voucher_no =")
                .doesNotContain("source_bill_no =");
    }

    @Test
    void everyGlProjectionUsesVoucherHeaderSourceUuid() throws IOException {
        String service = source(
                "src/main/java/com/uten/imp/features/finance/gl/GlPostingService.java");
        String normalized = canonical(service);
        String compact = service.replaceAll("\\s+", "");

        // Projection extraction must not silently remove a writer from the contract.
        Path glPackage = sourcePath("src/main/java/com/uten/imp/features/finance/gl");
        try (var files = Files.list(glPackage)) {
            List<Path> projections = files.filter(path -> path.getFileName().toString().equals("GlPostingService.java")
                    || path.getFileName().toString().endsWith("GlProjection.java")).toList();
            assertThat(projections).extracting(path -> path.getFileName().toString())
                    .contains("GlPostingService.java", "ActualInventoryCostGlProjection.java", "SubcontractWasteLossGlProjection.java");
            for (Path projection : projections) {
                String text = Files.readString(projection, StandardCharsets.UTF_8);
                assertEveryInsertCarriesSourceUuid(text, "gl_vouchers", "source_type", projection);
                assertEveryInsertCarriesSourceUuid(text, "gl_entries", "source_doc_type", projection);
            }
        }
        assertThat(compact).contains(
                "source_type,source_doc_id,source_ref,idempotency_key,reversal_of_voucher_id,remark");
        assertThat(normalized)
                .contains("'AUTO', 'AR_POST', l.source_doc_id")
                .contains("'AUTO', 'AP_POST', l.source_doc_id")
                .contains("'AUTO', 'PAYMENT', t.id")
                .contains("'AUTO', 'EXPENSE', t.id")
                .contains("'AUTO', 'INCOME', t.id")
                .contains("'AUTO', 'BANK_TRANSFER', t.id")
                .contains("'AUTO', 'EXPENSE', :doc")
                .contains("'AUTO','SUPPLIER_CLAIM_LEDGER',ledger.source_doc_id")
                .contains("'AUTO','SUPPLIER_CLAIM_OFFSET',allocation.offset_batch_id")
                .contains("'AUTO','SUPPLIER_CLAIM_RECEIVABLE',claim.id")
                .contains("'AUTO','SUPPLIER_CLAIM_CASH',receipt.id")
                .contains("'AUTO','CUSTOMER_PREPAYMENT_OFFSET',batch.id")
                .contains("'AUTO','BALANCE_ADJUSTMENT',batch.id")
                .contains("'AUTO','RECEIPT', :receiptId")
                .contains("'AUTO','RECEIPT_REV'")
                .contains("reversal_of_voucher_id")
                .contains("voucher.source_doc_id=:sourceDocId")
                .contains("voucher.source_doc_id=:expenseId")
                .contains("WHERE e.id = v.source_doc_id")
                .contains("AND ledger.source_doc_id IS NULL");
        assertThat(count(
                normalized,
                "voucher.source_type='BALANCE_ADJUSTMENT' AND voucher.source_doc_id=batch.id"))
                .isEqualTo(2);

        assertThat(normalized)
                .doesNotContain("JOIN gl_vouchers v ON v.voucher_no")
                .doesNotContain("voucher.voucher_no=:billNo")
                .doesNotContain("WHERE e.bill_no = v.voucher_no");

        String actual = canonical(source("src/main/java/com/uten/imp/features/finance/gl/ActualInventoryCostGlProjection.java"));
        assertThat(actual)
                .contains("'AUTO','ACTUAL_COGS',posting_id")
                .contains("voucher.voucher_date,voucher.period,'ACTUAL_COGS',cost.posting_id")
                .contains("voucher.source_type='ACTUAL_COGS' AND voucher.source_doc_id=cost.posting_id")
                .contains("SELECT cost.posting_id,voucher.id,cost.source_period,cost.target_period,cost.event_id,cost.node_id")
                .doesNotContain("DELETE FROM gl_vouchers")
                .doesNotContain("voucher.voucher_no=cost.");
        assertThat(count(actual, "voucher.source_type='ACTUAL_COGS' AND voucher.source_doc_id=cost.posting_id"))
                .as("Both entry and immutable link use the exact posting UUID").isEqualTo(2);
        assertThat(compact).contains("ActualInventoryCostGlProjection.postReady(em,period)");
        assertThat(GlPostingService.REGENERATED_SOURCE_TYPES)
                .doesNotContain("ACTUAL_COGS", "COST_CARRY");

        String subcontract = canonical(source("src/main/java/com/uten/imp/features/finance/gl/SubcontractWasteLossGlProjection.java"));
        assertThat(subcontract).contains("'AUTO','SUBCONTRACT_ABNORMAL_LOSS',loss.waste_id");
        assertThat(count(subcontract, "voucher.period,'SUBCONTRACT_ABNORMAL_LOSS',loss.waste_id"))
                .as("Debit and credit carry the same immutable waste document UUID").isEqualTo(2);
        assertThat(count(subcontract, "AND voucher.source_doc_id=loss.waste_id"))
                .as("Both legs join their header by source UUID").isEqualTo(2);
    }

    private static void assertEveryInsertCarriesSourceUuid(String source, String table, String typeColumn, Path owner) {
        var inserts = Pattern.compile("INSERT\\s+INTO\\s+" + table + "\\s*\\(([^)]+)\\)", Pattern.CASE_INSENSITIVE)
                .matcher(source);
        int inspected = 0;
        while (inserts.find()) {
            inspected++;
            List<String> columns = List.of(inserts.group(1).replaceAll("\\s+", "").split(","));
            assertThat(columns).as(owner + " " + table + " insert " + inspected)
                    .contains(typeColumn, "source_doc_id");
        }
        assertThat(inspected).as(owner + " must expose every " + table + " insert to the source contract")
                .isPositive().isEqualTo(count(source, "INSERT INTO " + table));
    }

    private static int count(String source, String token) {
        int result = 0;
        for (int offset = 0; (offset = source.indexOf(token, offset)) >= 0; offset += token.length()) {
            result++;
        }
        return result;
    }

    private static String source(String serverRelativePath) throws IOException {
        return Files.readString(sourcePath(serverRelativePath), StandardCharsets.UTF_8);
    }

    private static Path sourcePath(String serverRelativePath) {
        Path direct = Path.of(serverRelativePath);
        return Files.exists(direct) ? direct : Path.of("server").resolve(serverRelativePath);
    }

    private static String canonical(String value) {
        return value.replaceAll("\\s+", " ").trim();
    }
}
