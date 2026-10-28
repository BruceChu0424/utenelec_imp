package com.uten.imp.common.mastercode;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Locale;
import java.util.UUID;

/** Read-only checks of the same lifetime ownership rule enforced by database triggers. */
@Service
@RequiredArgsConstructor
public class MasterIdentifierAvailabilityService {
    private final EntityManager em;

    public enum Domain {
        GOODS("goods"), CLIENT("clients"), SUPPLIER("suppliers"), MOULD("moulds"),
        COLOR("colors"), UNIT("units"), ACCOUNT("accounts"), CURRENCY("currencies"), WAREHOUSE("warehouses");

        private final String table;
        Domain(String table) { this.table = table; }
    }

    public record Availability(String normalizedCode, boolean available, String message) {}

    @Transactional(readOnly = true)
    public Availability check(Domain domain, String code, UUID entityId) {
        return check(domain, code, entityId, null);
    }

    @Transactional(readOnly = true)
    public Availability check(Domain domain, String code, UUID entityId, UUID categoryId) {
        return checkInternal(domain, code, entityId, categoryId, false, true);
    }

    /** A planned category may be new; null explicitly means the domain fallback prefix. */
    @Transactional(readOnly = true)
    public Availability checkForTargetCategory(Domain domain, String code, UUID entityId, UUID categoryId) {
        return checkInternal(domain, code, entityId, categoryId, false, false);
    }

    /** Trusted object-version restoration keeps a soft-deleted entity's original UUID. */
    @Transactional(readOnly = true)
    public Availability checkForRestore(Domain domain, String code, UUID entityId, UUID categoryId) {
        if (entityId == null) throw new ApiException(ErrorCode.CONFLICT, "编号恢复缺少原资料身份");
        return checkInternal(domain, code, entityId, categoryId, true, true);
    }

    private Availability checkInternal(Domain domain, String code, UUID entityId, UUID categoryId,
                                       boolean includeDeleted, boolean inheritCurrentCategory) {
        Availability result = check(em, domain, code, entityId, includeDeleted);
        if (!result.available()) return result;
        boolean categoryDriven = domain == Domain.GOODS || domain == Domain.CLIENT
                || domain == Domain.SUPPLIER || domain == Domain.MOULD;
        if (result.normalizedCode() == null && (!categoryDriven || entityId == null || includeDeleted)) return result;
        if (domain == Domain.WAREHOUSE && "001".equals(result.normalizedCode())) {
            Object root = em.createNativeQuery("SELECT fn_warehouse_root_id()").getSingleResult();
            if (root != null && !root.equals(entityId)) return new Availability("001", false, "编号001由主仓专用，普通子仓不能使用");
        }
        if (categoryDriven) {
            UUID category = categoryId;
            if (inheritCurrentCategory && category == null && entityId != null) {
                Object existing = em.createNativeQuery("SELECT category_id FROM " + domain.table + " WHERE id=:id")
                        .setParameter("id", entityId).getSingleResult();
                category = existing == null ? null : (UUID) existing;
            }
            var categories = new CategoryDrivenCodeService(em);
            var type = CategoryDrivenCodeService.MasterType.valueOf(domain.name());
            if (entityId != null && !includeDeleted) {
                try {
                    categories.previewForUpdate(type, entityId, category, code);
                    return result;
                } catch (ApiException invalid) {
                    if (invalid.getCode() != ErrorCode.CONFLICT && invalid.getCode() != ErrorCode.VALIDATION_FAILED) throw invalid;
                    return new Availability(result.normalizedCode(), false, invalid.getMessage());
                }
            }
            String problem = categories.requestedSequenceProblem(type, result.normalizedCode(), entityId, category);
            if (problem != null) return new Availability(result.normalizedCode(), false, problem);
        }
        return result;
    }

    static Availability check(EntityManager em, Domain domain, String code, UUID entityId) {
        return check(em, domain, code, entityId, false);
    }

    static Availability check(EntityManager em, Domain domain, String code, UUID entityId, boolean includeDeleted) {
        String normalized = code == null ? "" : code.strip().toUpperCase(Locale.ROOT);
        if (normalized.isEmpty()) return new Availability(null, true, null);
        if (entityId != null) {
            boolean exists = Boolean.TRUE.equals(em.createNativeQuery(
                    "SELECT EXISTS (SELECT 1 FROM " + domain.table + " WHERE id=:id" + (includeDeleted ? "" : " AND is_deleted=false") + ")")
                    .setParameter("id", entityId).getSingleResult());
            if (!exists) throw new ApiException(ErrorCode.NOT_FOUND, "资料不存在，请刷新后重试");
        }
        // The current owner may keep a legacy shared code. A historical code can
        // be reclaimed only when no other logical identity has ever owned it.
        boolean available = Boolean.TRUE.equals(em.createNativeQuery("""
                SELECT NOT EXISTS (
                    SELECT 1 FROM business_identifier_reservations reservation
                    WHERE normalized_identifier=:code COLLATE "C"
                      AND NOT (
                        EXISTS (SELECT 1 FROM business_identifier_reservation_members member
                            WHERE member.normalized_identifier=reservation.normalized_identifier
                              AND member.owner_domain=:domain AND member.entity_id=CAST(:id AS uuid)
                              AND NOT (:domain='GOODS' AND EXISTS(SELECT 1 FROM goods_code_reuse_releases released
                                  WHERE released.normalized_code=member.normalized_identifier AND released.old_goods_id=member.entity_id)))
                        AND (EXISTS (SELECT 1 FROM %s current_master
                                WHERE current_master.id=CAST(:id AS uuid)
                                  AND upper(btrim(current_master.code))=:code COLLATE "C")
                            OR NOT EXISTS (
                                SELECT 1 FROM business_identifier_reservation_members other
                                WHERE other.normalized_identifier=reservation.normalized_identifier
                                  AND NOT (other.owner_domain=:domain AND other.entity_id=CAST(:id AS uuid))))))
                """.formatted(domain.table))
                .setParameter("code", normalized)
                .setParameter("domain", domain.name())
                .setParameter("id", entityId)
                .getSingleResult());
        if (!available && domain == Domain.GOODS && entityId == null) {
            available = em.createNativeQuery("SELECT fn_goods_code_reusable_owner(:code)")
                    .setParameter("code", normalized).getSingleResult() instanceof UUID;
        }
        return new Availability(normalized, available,
                available ? null : "编号已存在或已被历史资料使用，请更换编号");
    }
}
