package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ClientDefaultSettlementMethodUuidContractTest {
    private static final Path ROOT = Path.of("..");

    @Test
    void v285BackfillsOnlyExactActiveMatchesAndPersistsReconciliationEvidence()
            throws IOException {
        String sql = read("server/src/main/resources/db/migration/"
                + "V285__client_default_settlement_method_uuid.sql");
        String normalized = sql.replaceAll("\\s+", " ").toLowerCase(Locale.ROOT);

        assertTrue(normalized.contains("add column default_settlement_method_id uuid"));
        assertTrue(normalized.contains("create table client_default_settlement_migration_issues"));
        assertTrue(normalized.contains("status = '使用'"));
        assertTrue(normalized.contains("coalesce(is_deleted, false) = false"));
        assertTrue(normalized.contains("count(*)::int as match_count"));
        assertTrue(normalized.contains("matches.match_count = 1"));
        assertTrue(normalized.contains("missing_active_method"));
        assertTrue(normalized.contains("ambiguous_active_method"));
        assertTrue(normalized.contains("active_match_count"));
        assertTrue(normalized.contains("fk_clients_default_settlement_method"));
        assertTrue(normalized.contains("validate constraint fk_clients_default_settlement_method"));
        assertTrue(normalized.contains("trg_client_default_settlement_reference"));
        assertTrue(normalized.contains("trg_guard_client_default_settlement_method_target"));
        assertTrue(normalized.contains("trg_audit_client_default_settlement_migration_issues"));
        assertTrue(normalized.contains("audit_trigger.tgenabled in ('o', 'a')"));
    }

    @Test
    void cashRoleAndImportEscapeHatchesAreExplicitAndControlled() throws IOException {
        String sql = read("server/src/main/resources/db/migration/"
                + "V285__client_default_settlement_method_uuid.sql");
        String normalized = sql.replaceAll("\\s+", " ").toLowerCase(Locale.ROOT);

        assertTrue(normalized.contains("system_role = 'cash'"));
        assertTrue(normalized.contains("system settlement role/code is immutable"));
        assertTrue(normalized.contains("uten.system_settlement_role_maintenance"));
        assertTrue(normalized.contains("in ('on', 'true', '1')"));
        assertFalse(normalized.contains(
                "current_setting('uten.legacy_reference_import', true), '') <> ''"));
    }

    @Test
    void runtimeAndClientEditorCarryOnlyUuidAuthority() throws IOException {
        String clientService = read("server/src/main/java/com/uten/imp/features/master/"
                + "client/ClientService.java");
        String resolver = read("server/src/main/java/com/uten/imp/common/util/"
                + "SettlementMethodReferenceResolver.java");
        String shipment = read("server/src/main/java/com/uten/imp/features/sales/"
                + "shipment/SalesShipmentService.java");
        String model = read("lib/features/basic_data/models/client_node.dart");
        String page = read("lib/features/basic_data/pages/client_category_page.dart");

        assertTrue(clientService.contains("hasDefaultSettlementMethodReference"));
        assertTrue(clientService.contains("SettlementMethodReferenceResolver.resolve("));
        assertFalse(clientService.contains("method.legacy_id ="));
        assertFalse(resolver.contains("resolvePersistedLegacyDefault"));
        assertFalse(resolver.contains("method.legacy_id = :value"));
        assertTrue(shipment.contains("headerReferencePresent"));
        assertTrue(shipment.contains("defaults.defaultSettlementMethodId()"));
        assertTrue(shipment.contains("SETTLEMENT_ROLE_CASH.equals(method.systemRole())"));
        assertFalse(shipment.contains("priceStyle == 1"));
        assertTrue(model.contains("defaultSettlementMethodId"));
        assertTrue(page.contains("key: 'defaultSettlementMethodId'"));
        assertTrue(page.contains("m.defaultSettlementMethodName"));
    }

    @Test
    void explicitLegacyClientLoaderWritesUuidAndRecordsUnresolvedRows()
            throws IOException {
        String sql = read("server/legacy_migration/migrate_client_data.sql");

        assertTrue(sql.contains("set_config('uten.legacy_reference_import', 'on', true)"));
        assertTrue(sql.contains(
                "default_settlement_method_id, sales_payment_type, price_style"));
        assertTrue(sql.contains("credit, credit_floor"));
        assertTrue(sql.contains("LEFT JOIN settlement_matches"));
        assertTrue(sql.contains("client_default_settlement_migration_issues"));
    }

    private static String read(String relative) throws IOException {
        return Files.readString(ROOT.resolve(relative), StandardCharsets.UTF_8);
    }
}
