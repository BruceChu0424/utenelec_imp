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

        for (String role : new String[]{
                "ar_control", "sales_revenue", "inventory_asset", "ap_control",
                "sales_cost", "bank_fee_expense", "fx_gain_loss"}) {
            assertThat(java).contains("system_posting_style_id('" + role + "')");
        }
        assertThat(java)
                .contains("assertrequiredsystempostingroles(period)")
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
