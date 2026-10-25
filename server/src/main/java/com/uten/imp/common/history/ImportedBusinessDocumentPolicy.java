package com.uten.imp.common.history;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.ImportedDocumentLifecycleCapabilities;
import jakarta.persistence.EntityManager;
import java.util.Collection;
import java.util.UUID;

/** Early business-command check; V926 independently protects every persisted parent/child/source. */
public final class ImportedBusinessDocumentPolicy {
    private ImportedBusinessDocumentPolicy() { }

    public static <T> T mutable(T record) {
        if (record == null || !businessRecord(record.getClass())) return record;
        for (String property : new String[]{"getLegacyId", "getLegacyImportRunId"}) {
            try {
                if (record.getClass().getMethod(property).invoke(record) != null) reject();
            } catch (NoSuchMethodException absent) {
                // Entity generations without a mapped run column are still covered by V926.
            } catch (ReflectiveOperationException failure) {
                throw new IllegalStateException("Cannot verify business document origin", failure);
            }
        }
        return record;
    }

    private static boolean businessRecord(Class<?> type) {
        for (Class<?> current = type; current != null; current = current.getSuperclass()) {
            var table = current.getAnnotation(jakarta.persistence.Table.class);
            if (table == null) continue;
            String name = table.name();
            if (java.util.Set.of("goods", "goods_bom_items", "employees", "users", "departments",
                    "warehouses", "units", "colors", "currencies", "clients", "suppliers", "moulds",
                    "accounts", "stock_balances").contains(name) || name.startsWith("stock_value_")) return false;
            String domain = current.getPackageName();
            return java.util.List.of("sales", "purchase", "subcontract", "production", "stock", "finance", "expenseclaim")
                    .stream().anyMatch(part -> domain.startsWith("com.uten.imp.features." + part + "."));
        }
        return false;
    }

    /** Loaded legacy IDs fail without another lookup; native-looking rows also check actual run/source provenance. */
    public static <T> T mutable(EntityManager em, String table, T record) {
        mutable(record);
        if (record == null) return null;
        try {
            requireMutable(em, table, (UUID) record.getClass().getMethod("getId").invoke(record));
            return record;
        } catch (ReflectiveOperationException failure) {
            throw new IllegalStateException("Cannot verify business document identity", failure);
        }
    }

    /** Call only after the domain has checked object read/write scope. Table names are server owned. */
    public static void requireMutable(EntityManager em, String table, UUID id) {
        if (id != null && Boolean.TRUE.equals(em.createNativeQuery(
                "SELECT fn_imported_business_document(:table,:id)")
                .setParameter("table", table).setParameter("id", id).getSingleResult())) reject();
    }

    public static void requireNativeSources(EntityManager em, String table, Collection<UUID> ids) {
        if (ids == null || ids.isEmpty()) return;
        if (!table.matches("[a-z][a-z0-9_]*")) throw new IllegalArgumentException("Invalid internal business table");
        if (!em.createNativeQuery("SELECT id FROM public." + table
                + " WHERE id IN (:ids) AND fn_imported_business_document(:table,id)")
                .setParameter("table", table).setParameter("ids", ids).getResultList().isEmpty()) reject();
    }

    private static void reject() {
        throw new ApiException(ErrorCode.BUSINESS, ImportedDocumentLifecycleCapabilities.READ_ONLY_REASON);
    }
}
