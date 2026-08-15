package com.uten.imp.migration;

import com.uten.imp.features.master.client.dto.ClientSaveRequest;
import com.uten.imp.features.master.mould.dto.MouldSaveRequest;
import com.uten.imp.features.master.supplier.dto.SupplierSaveRequest;
import jakarta.validation.constraints.NotNull;
import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class UncategorizedMasterCategoryContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/V272__uncategorized_master_categories.sql");

    @Test
    void migrationCreatesProtectedRootsBackfillsAndClosesNullCategoryColumns() throws Exception {
        String sql = compact(Files.readString(MIGRATION));

        assertThat(sql)
                .contains("-1, 'sys_uncategorized_client'")
                .contains("-1, 'sys_uncategorized_mould'")
                .contains("-1, 'sys_uncategorized_supplier'")
                .contains("update clients set category_id =")
                .contains("update moulds set category_id =")
                .contains("update suppliers set category_id =")
                .contains("active master records still reference deleted categories")
                .contains("active master category is missing or deleted")
                .contains("alter table clients alter column category_id set not null")
                .contains("alter table moulds alter column category_id set not null")
                .contains("alter table suppliers alter column category_id set not null")
                .contains("fn_assign_uncategorized_master_category")
                .contains("fn_protect_uncategorized_master_category")
                .contains("fn_guard_category_soft_delete_with_active_masters");
    }

    @Test
    void everyPublicMasterSaveRequestRequiresCategory() throws Exception {
        assertThat(ClientSaveRequest.class.getDeclaredField("categoryId").getAnnotation(NotNull.class))
                .isNotNull();
        assertThat(MouldSaveRequest.class.getDeclaredField("categoryId").getAnnotation(NotNull.class))
                .isNotNull();
        assertThat(SupplierSaveRequest.class.getDeclaredField("categoryId").getAnnotation(NotNull.class))
                .isNotNull();
    }

    @Test
    void everyOfflineMigrationRecreatesOrUsesTheSystemRoot() throws Exception {
        for (String domain : new String[]{"client", "mould", "supplier"}) {
            String category = compact(Files.readString(Path.of(
                    "legacy_migration/migrate_" + domain + ".sql")));
            String data = compact(Files.readString(Path.of(
                    "legacy_migration/migrate_" + domain + "_data.sql")));
            assertThat(category)
                    .contains("system_master_category_registry")
                    .contains("registry." + domain + "_category_id")
                    .contains("category.legacy_id = -1")
                    .contains("category.is_deleted = false")
                    .contains("where id = '27500000-0000-4000-8000-000000000001'::uuid")
                    .doesNotContain("values (-1, 'sys_uncategorized_");
            assertThat(data)
                    .contains("coalesce(")
                    .contains("system_master_category_registry")
                    .contains("select " + domain + "_category_id")
                    .contains("where id = '27500000-0000-4000-8000-000000000001'::uuid")
                    .doesNotContain("where c.legacy_id = -1");
        }

        String finance = compact(Files.readString(Path.of("legacy_migration/migrate_finance.sql")));
        assertThat(finance)
                .contains("select client_category_id from system_master_category_registry")
                .contains("select supplier_category_id from system_master_category_registry")
                .contains("set category_id = coalesce(clients.category_id, excluded.category_id)")
                .contains("set category_id = coalesce(suppliers.category_id, excluded.category_id)")
                .doesNotContain("select id from client_categories where legacy_id = -1")
                .doesNotContain("select id from supplier_categories where legacy_id = -1");
    }

    private static String compact(String value) {
        return value.toLowerCase().replaceAll("\\s+", " ");
    }
}
