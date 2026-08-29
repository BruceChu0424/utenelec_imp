package com.uten.imp.features.finance.gl;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

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

        assertThat(count(service, "INSERT INTO gl_vouchers")).isEqualTo(17);
        assertThat(count(compact, "source_type,source_doc_id,remark")).isEqualTo(16);
        assertThat(compact).contains(
                "source_type,source_doc_id,source_ref,idempotency_key,reversal_of_voucher_id,remark");
        assertThat(normalized)
                .contains("'AUTO', 'AR_POST', l.source_doc_id")
                .contains("'AUTO', 'AP_POST', l.source_doc_id")
                .contains("'AUTO', 'RECEIPT', t.id")
                .contains("'AUTO', 'PAYMENT', t.id")
                .contains("'AUTO', 'EXPENSE', t.id")
                .contains("'AUTO', 'INCOME', t.id")
                .contains("'AUTO', 'COST_CARRY', d.id")
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
    }

    private static int count(String source, String token) {
        int result = 0;
        for (int offset = 0; (offset = source.indexOf(token, offset)) >= 0; offset += token.length()) {
            result++;
        }
        return result;
    }

    private static String source(String serverRelativePath) throws IOException {
        Path direct = Path.of(serverRelativePath);
        Path path = Files.exists(direct) ? direct : Path.of("server").resolve(serverRelativePath);
        return Files.readString(path, StandardCharsets.UTF_8);
    }

    private static String canonical(String value) {
        return value.replaceAll("\\s+", " ").trim();
    }
}
