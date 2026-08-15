package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class MasterCodeLifetimeReservationMigrationContractTest {

    @Test
    void v276ReservesTrimmedCaseInsensitiveCodesForEveryBusinessMasterDomain()
            throws IOException {
        String sql = compact(read("src/main/resources/db/migration/"
                + "V276__master_code_lifetime_reservations.sql"));

        assertThat(sql)
                .contains("create table master_code_reservations")
                .contains("create table master_code_reservation_members")
                .contains("normalized_code = upper(btrim(normalized_code))")
                .contains("v_normalized_code := upper(v_code_snapshot)")
                .contains("code must not be blank")
                .contains("master code is reserved for another identity")
                .contains("master-code reservations never expire")
                .contains("current_setting('app.master_code_audit_stage', true) = 'temporary'")
                .contains("tg_op = 'insert' and v_same_legacy_member")
                .contains("tg_op = 'update' and v_self_member")
                .contains("for each row execute function fn_audit()")
                .contains("trg_guard_master_code_reservations_append_only")
                .contains("trg_guard_master_code_reservation_members_append_only");

        for (String table : new String[]{
                "goods", "moulds", "clients", "suppliers", "colors", "units",
                "currencies", "warehouses", "accounts", "payment_styles",
                "settlement_methods", "finance_payment_methods", "material_categories",
                "mould_categories", "client_categories", "supplier_categories",
                "employees", "departments", "positions", "fixed_assets",
                "deferred_expenses", "finance_asset_categories"
        }) {
            assertThat(sql).contains("trg_reserve_code_" + table);
        }
    }

    @Test
    void v276PreservesIntentionalScopesAndVersionedPolicyFamilies()
            throws IOException {
        String sql = compact(read("src/main/resources/db/migration/"
                + "V276__master_code_lifetime_reservations.sql"));

        assertThat(sql)
                .contains("'position/' || department_id::text")
                .contains("fn_reserve_master_code('position', 'department_id', '')")
                .contains("'finance_asset_category/' || object_type")
                .contains("fn_reserve_master_code('finance_asset_category', 'object_type', 'code')")
                .contains("historical duplicates are registered as legacy members")
                .doesNotContain("update goods set code")
                .doesNotContain("update colors set code");
    }

    private static String read(String serverRelativePath) throws IOException {
        Path direct = Path.of(serverRelativePath);
        Path path = Files.exists(direct) ? direct : Path.of("server").resolve(serverRelativePath);
        return Files.readString(path.normalize(), StandardCharsets.UTF_8);
    }

    private static String compact(String value) {
        return value.toLowerCase(Locale.ROOT).replaceAll("\\s+", " ").trim();
    }
}
