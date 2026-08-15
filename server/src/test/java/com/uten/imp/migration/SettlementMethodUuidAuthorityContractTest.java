package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SettlementMethodUuidAuthorityContractTest {
    private static final Path ROOT = Path.of("..");

    @Test
    void v273SeparatesSettlementTermsFromFinanceInstrumentsAndGuardsEveryHeader()
            throws IOException {
        String migration = read("server/src/main/resources/db/migration/"
                + "V273__settlement_method_uuid_authority.sql");

        assertTrue(migration.contains("CREATE TABLE settlement_methods"));
        assertTrue(migration.contains("CREATE TABLE finance_payment_methods"));
        assertTrue(migration.contains("legacy_name_confirmed BOOLEAN NOT NULL DEFAULT FALSE"));
        assertTrue(migration.contains("AND (legacy_name_confirmed"));
        assertTrue(migration.contains("OR COALESCE(current_setting('uten.legacy_reference_import'"));
        assertTrue(migration.contains("trg_finance_method_ref_expenses"));
        assertTrue(migration.contains("fk_finance_expenses_method"));
        assertTrue(migration.contains("trg_settlement_ref_ar_ap_ledger"));
        assertFalse(migration.contains("REFERENCES payment_styles(id)"));
    }

    @Test
    void normalApiAndPickerExcludeUnconfirmedLegacyNamePlaceholders() throws IOException {
        String resolver = read("server/src/main/java/com/uten/imp/common/util/"
                + "PaymentMethodReferenceResolver.java");
        String settlementResolver = read("server/src/main/java/com/uten/imp/common/util/"
                + "SettlementMethodReferenceResolver.java");
        String repository = read("server/src/main/java/com/uten/imp/features/master/"
                + "referencemethod/FinancePaymentMethodRepository.java");
        String service = read("server/src/main/java/com/uten/imp/features/master/"
                + "referencemethod/ReferenceMethodService.java");

        assertTrue(resolver.contains("method.legacy_name_confirmed = true"));
        assertTrue(resolver.contains("必须使用系统 UUID"));
        assertFalse(resolver.contains("method.legacy_id = :value"));
        assertTrue(settlementResolver.contains("必须使用系统 UUID"));
        assertFalse(settlementResolver.contains("resolvePersistedLegacyDefault"));
        assertFalse(settlementResolver.contains("method.legacy_id = :value"));
        assertTrue(resolver.contains("名称尚未确认"));
        assertFalse(resolver.contains("不是末级 METHOD"));
        assertTrue(repository.contains("findByLegacyNameConfirmedTrue"));
        assertTrue(service.contains("findByLegacyNameConfirmedTrue"));
    }

    @Test
    void shipmentUsesHeaderThenClientDefaultUuidBeforeAuthoritativeArWrite()
            throws IOException {
        String shipment = read("server/src/main/java/com/uten/imp/features/sales/"
                + "shipment/SalesShipmentService.java");

        assertFalse(shipment.contains("resolvePersistedLegacyDefault"));
        assertTrue(shipment.contains("client.default_settlement_method_id"));
        assertTrue(shipment.contains("headerReferencePresent"));
        assertTrue(shipment.contains("method.systemRole()"));
        assertFalse(shipment.contains("clientPriceStyle == 1"));
        assertTrue(shipment.contains("settlement.settlementMethodId()"));
        assertTrue(shipment.contains("s.setSettlementMethodId("));
        assertTrue(shipment.contains("s.setPaymentStyleId("));
    }

    @Test
    void legacyAndFlutterChainsCarryUuidTruthIncludingExpensePaidStyle() throws IOException {
        String legacy = read("server/legacy_migration/migrate_finance.sql");
        String model = read("lib/features/finance/models/finance_doc.dart");
        String edit = read("lib/features/finance/pages/finance_doc_edit_page.dart");

        assertTrue(legacy.contains("CREATE TEMP TABLE recstyle_stage"));
        assertTrue(legacy.contains("legacy_name_confirmed = TRUE"));
        assertTrue(legacy.contains("payment_method_legacy_id, status, remark"));
        assertTrue(legacy.contains("UPDATE finance_expenses expense"));
        assertTrue(model.contains("final String? paymentMethodId"));
        assertTrue(edit.contains("'receiptMethodId': _financePaymentMethodId"));
        assertTrue(edit.contains("'paymentMethodId': _financePaymentMethodId"));
        assertFalse(edit.contains("'paymentMethodLegacyId':"));
        assertFalse(edit.contains("'receiptMethodLegacyId':"));
    }

    private static String read(String relative) throws IOException {
        return Files.readString(ROOT.resolve(relative));
    }
}
