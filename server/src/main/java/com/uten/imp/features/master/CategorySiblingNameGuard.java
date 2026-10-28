package com.uten.imp.features.master;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;

import java.util.UUID;

/** Shared sibling-name contract. Call while holding the domain hierarchy lock. */
public final class CategorySiblingNameGuard {
    private CategorySiblingNameGuard() {}

    public enum Kind {
        MATERIAL("material_categories"), CLIENT("client_categories"),
        SUPPLIER("supplier_categories"), MOULD("mould_categories"),
        PAYMENT_STYLE("payment_styles");
        private final String table;
        Kind(String table) { this.table = table; }
    }

    public static String normalize(String name) {
        if (name == null || name.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请输入分类名称");
        }
        return name.strip();
    }

    public static void lockHierarchy(EntityManager em, Kind kind) {
        String lockKey = switch (kind) {
            case MATERIAL -> "MATERIAL_CATEGORY_HIERARCHY";
            case CLIENT -> "CLIENT_CATEGORY_HIERARCHY";
            case SUPPLIER -> "SUPPLIER_CATEGORY_HIERARCHY";
            case MOULD -> "MOULD_CATEGORY_HIERARCHY";
            case PAYMENT_STYLE -> "PAYMENT_STYLE_HIERARCHY";
        };
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:hierarchyLockKey,0))")
                .setParameter("hierarchyLockKey", lockKey).getSingleResult();
    }

    public static void requireAvailable(EntityManager em, Kind kind,
                                        String name, UUID parentId, UUID excludingId) {
        requireAvailable(em, kind, name, parentId, excludingId, null);
    }

    public static void requireAvailable(EntityManager em, Kind kind, String name,
                                        UUID parentId, UUID excludingId, String category) {
        String normalized = normalize(name);
        Query query = em.createNativeQuery("SELECT id FROM " + kind.table
                + " WHERE NOT is_deleted AND btrim(name)=:name"
                + " AND parent_id IS NOT DISTINCT FROM CAST(:parentId AS uuid)"
                + " AND id IS DISTINCT FROM CAST(:excludingId AS uuid)"
                + (kind == Kind.PAYMENT_STYLE ? " AND category=:category" : "")
                + " LIMIT 1");
        query.setParameter("name", normalized);
        query.setParameter("parentId", parentId);
        query.setParameter("excludingId", excludingId);
        if (kind == Kind.PAYMENT_STYLE) query.setParameter("category", category);
        if (!query.getResultList().isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "同一上级下已有分类“" + normalized + "”，请更换名称");
        }
    }
}
