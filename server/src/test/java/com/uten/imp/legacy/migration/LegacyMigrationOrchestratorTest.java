package com.uten.imp.legacy.migration;

import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class LegacyMigrationOrchestratorTest {

    @Test
    void failureReportContainsOnlyStableSummaryAndTraceableReference() {
        MaterialCategoryMigrator material = mock(MaterialCategoryMigrator.class);
        MouldCategoryMigrator mould = mock(MouldCategoryMigrator.class);
        ClientCategoryMigrator client = mock(ClientCategoryMigrator.class);
        SupplierCategoryMigrator supplier = mock(SupplierCategoryMigrator.class);
        when(material.migrateGoods()).thenThrow(
                new IllegalStateException("internal-detail-marker at jdbc-internal-host"));

        var report = new LegacyMigrationOrchestrator(
                material,
                mould,
                client,
                supplier).migrateAll();

        assertFalse(report.success());
        String serializedView = report.toString();
        assertFalse(serializedView.contains("internal-detail-marker"));
        assertFalse(serializedView.contains("jdbc-internal-host"));
        assertFalse(serializedView.contains("IllegalStateException"));

        @SuppressWarnings("unchecked")
        Map<String, String> failure =
                (Map<String, String>) report.modules().get("materialCategory.goods");
        assertTrue("LEGACY_MIGRATION_MODULE_FAILED".equals(failure.get("errorCode")));
        assertDoesNotThrow(() -> UUID.fromString(failure.get("referenceId")));
        assertTrue(report.error().contains(failure.get("referenceId")));

        verify(mould).migrateMoulds();
        verify(client).migrateClients();
        verify(supplier).migrateSuppliers();
    }
}
