package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class SystemPostingStyleUuidRoleContractTest {

    @Test
    void v278BackfillsReviewedLocatorsOnceAndProtectsUuidMappings() throws IOException {
        String sql = compact(read("src/main/resources/db/migration/"
                + "V278__system_posting_style_uuid_roles.sql"));

        assertThat(sql)
                .contains("create table system_posting_style_roles")
                .contains("role_key text primary key")
                .contains("style_id uuid unique references payment_styles(id) on delete restrict")
                .contains("having count(*) = 1")
                .contains("create trigger trg_system_posting_style_role_guard")
                .contains("system posting role keys and categories are immutable")
                .contains("create trigger trg_guard_mapped_system_posting_style")
                .contains("create trigger trg_audit_system_posting_style_roles")
                .contains("create or replace function system_posting_style_id")
                .contains("style.status = '使用'")
                .contains("coalesce(style.is_deleted, false) = false");

        String runtimeResolver = sql.substring(sql.indexOf(
                "create or replace function system_posting_style_id"));
        runtimeResolver = runtimeResolver.substring(0, runtimeResolver.indexOf("comment on table"));
        assertThat(runtimeResolver)
                .doesNotContain("style.path")
                .doesNotContain("style.name")
                .doesNotContain("style.code")
                .doesNotContain("limit 1")
                .doesNotContain("order by");
    }

    @Test
    void glPostingUsesOnlyStableRoleKeysAndChecksEveryConditionalRoleBeforeDelete()
            throws IOException {
        String java = compact(read(
                "src/main/java/com/uten/imp/features/finance/gl/GlPostingService.java"));

        // V607+ 重构后的 GL 角色键清单：银行手续费角色已移出 GL——收/付款审核时
        // 解析并持久化 gl_bank_fee_style_id，GL 只消费单据上的 UUID 真源。
        for (String role : new String[]{
                "ar_control", "sales_revenue", "inventory_asset", "ap_control",
                "sales_cost", "customer_advance", "fx_gain_loss",
                "supplier_claim_receivable", "subcontract_loss_recovery"}) {
            assertThat(java).contains("system_posting_style_id('" + role + "')");
        }
        assertThat(java)
                .contains("assertrequiredsystempostingroles(period)")
                .contains("system_posting_style_id(required.role_key)")
                .contains("receipt.gl_bank_fee_style_id")
                .contains("coalesce(receipt.bank_fee,0)<>0")
                .contains("having coalesce(sum(line.exchange_diff),0)<>0")
                .contains("from sales_shipments shipment")
                .contains("from ar_ap_ledger ledger")
                .doesNotContain("where path='/113/'")
                .doesNotContain("where path='/031/'")
                .doesNotContain("where path='/123/'")
                .doesNotContain("where path='/203/'")
                .doesNotContain("where path='/041/'")
                .doesNotContain("name='手续费'")
                .doesNotContain("name='汇兑损益'");
        // BANK_FEE_EXPENSE 的角色解析去向：收/付款服务审核时绑定持久化 UUID。
        String receiptSvc = compact(read(
                "src/main/java/com/uten/imp/features/finance/receipt/FinanceReceiptService.java"));
        String paymentSvc = compact(read(
                "src/main/java/com/uten/imp/features/finance/payment/FinancePaymentService.java"));
        assertThat(receiptSvc).contains("requiredpostingstyle(\"bank_fee_expense\")");
        assertThat(paymentSvc).contains("paymentpostingstyle(\"bank_fee_expense\")");
    }

    private static String read(String relative) throws IOException {
        Path direct = Path.of(relative).normalize();
        Path path = Files.exists(direct)
                ? direct : Path.of("server").resolve(relative).normalize();
        return Files.readString(path, StandardCharsets.UTF_8);
    }

    private static String compact(String value) {
        return value.toLowerCase(Locale.ROOT).replaceAll("\\s+", " ").trim();
    }
}
