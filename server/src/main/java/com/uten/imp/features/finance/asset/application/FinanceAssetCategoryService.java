package com.uten.imp.features.finance.asset.application;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.asset.api.AssetCategoryContracts;
import com.uten.imp.features.finance.asset.domain.AssetCategoryPolicyReadiness;
import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.sql.Date;
import java.time.LocalDate;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** Versioned enterprise-owned accounting policy for assets and deferrals. */
@Service
@RequiredArgsConstructor
public class FinanceAssetCategoryService {

    private static final TypeReference<List<String>> STRING_LIST = new TypeReference<>() {};
    private static final ZoneId SHANGHAI = ZoneId.of("Asia/Shanghai");

    private final EntityManager em;
    private final TxSessionVars tx;
    private final FinanceAssetAuthorization authorization;
    private final ObjectMapper objectMapper;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public List<AssetCategoryContracts.Category> list(String objectType) {
        authorization.require(FinanceAssetAuthorization.VIEW);
        String normalized = objectType(objectType);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT id, object_type, code, name, version, status, effective_from,
                       default_method, default_months, default_salvage_rate,
                       cost_style_id, accumulated_style_id, expense_style_id, clearing_style_id,
                       required_document_codes::text, row_version
                FROM finance_asset_categories
                WHERE object_type=:objectType AND is_deleted=false
                ORDER BY code, version DESC
                """)
                .setParameter("objectType", normalized)
                .getResultList();
        return rows.stream().map(this::map).toList();
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetCategoryContracts.Category create(AssetCategoryContracts.SaveRequest request) {
        tx.bind();
        PaymentStyleHierarchyLock.lock(em);
        UUID actorId = authorization.requireActorId(FinanceAssetAuthorization.APPROVE);
        String objectType = objectType(request.objectType());
        String code = requiredText(request.code(), "code").toUpperCase();
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                .setParameter("key", "FINANCE_ASSET_CATEGORY|" + objectType + "|" + code)
                .getSingleResult();
        int version = ((Number) em.createNativeQuery("""
                SELECT COALESCE(MAX(version),0)+1
                FROM finance_asset_categories
                WHERE object_type=:objectType AND code=:code
                """)
                .setParameter("objectType", objectType)
                .setParameter("code", code)
                .getSingleResult()).intValue();
        UUID id = UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO finance_asset_categories
                    (id, object_type, code, name, cost_style_id, accumulated_style_id,
                     expense_style_id, clearing_style_id, default_method, default_months,
                     default_salvage_rate, required_document_codes, effective_from,
                     status, version, remark, created_by, updated_by)
                VALUES
                    (:id, :objectType, :code, :name, :cost, :accumulated,
                     :expense, :clearing, :method, :months,
                     :salvage, CAST(:documents AS jsonb), :effectiveFrom,
                     'DRAFT', :version, :remark, :actor, :actor)
                """)
                .setParameter("id", id)
                .setParameter("objectType", objectType)
                .setParameter("code", code)
                .setParameter("name", requiredText(request.name(), "name"))
                .setParameter("cost", request.costStyleId())
                .setParameter("accumulated", request.accumulatedStyleId())
                .setParameter("expense", request.expenseStyleId())
                .setParameter("clearing", request.clearingStyleId())
                .setParameter("method", request.defaultMethod())
                .setParameter("months", request.defaultUsefulMonths())
                .setParameter("salvage", request.defaultResidualRate())
                .setParameter("documents", json(request.requiredDocumentCodes()))
                .setParameter("effectiveFrom", request.effectiveFrom())
                .setParameter("version", version)
                .setParameter("remark", request.remark())
                .setParameter("actor", actorId)
                .executeUpdate();
        return get(id);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetCategoryContracts.Category update(UUID id, AssetCategoryContracts.SaveRequest request) {
        tx.bind();
        PaymentStyleHierarchyLock.lock(em);
        UUID actorId = authorization.requireActorId(FinanceAssetAuthorization.APPROVE);
        CategoryLock current = lock(id);
        requireDraftAndVersion(current, request.expectedVersion());
        if (!current.objectType().equals(objectType(request.objectType()))
                || !current.code().equalsIgnoreCase(request.code())) {
            throw new ApiException(ErrorCode.CONFLICT, "Category objectType and code are immutable; create a new version");
        }
        Number references = (Number) em.createNativeQuery("""
                SELECT (SELECT COUNT(*) FROM fixed_assets WHERE category_id=:id AND is_deleted=false)
                     + (SELECT COUNT(*) FROM deferred_expenses WHERE category_id=:id AND is_deleted=false)
                     + (SELECT COUNT(*) FROM finance_asset_books b JOIN fixed_assets a ON a.id=b.asset_id
                        WHERE a.category_id=:id AND b.is_deleted=false)
                """).setParameter("id", id).getSingleResult();
        if (references.longValue() != 0) {
            throw new ApiException(ErrorCode.CONFLICT, "A referenced policy version cannot be edited; create a new version");
        }
        int changed = em.createNativeQuery("""
                UPDATE finance_asset_categories
                SET name=:name, cost_style_id=:cost, accumulated_style_id=:accumulated,
                    expense_style_id=:expense, clearing_style_id=:clearing,
                    default_method=:method, default_months=:months,
                    default_salvage_rate=:salvage,
                    required_document_codes=CAST(:documents AS jsonb),
                    effective_from=:effectiveFrom, remark=:remark,
                    row_version=row_version+1, updated_at=now(), updated_by=:actor
                WHERE id=:id AND status='DRAFT' AND row_version=:version AND is_deleted=false
                """)
                .setParameter("name", requiredText(request.name(), "name"))
                .setParameter("cost", request.costStyleId())
                .setParameter("accumulated", request.accumulatedStyleId())
                .setParameter("expense", request.expenseStyleId())
                .setParameter("clearing", request.clearingStyleId())
                .setParameter("method", request.defaultMethod())
                .setParameter("months", request.defaultUsefulMonths())
                .setParameter("salvage", request.defaultResidualRate())
                .setParameter("documents", json(request.requiredDocumentCodes()))
                .setParameter("effectiveFrom", request.effectiveFrom())
                .setParameter("remark", request.remark())
                .setParameter("actor", actorId)
                .setParameter("id", id)
                .setParameter("version", current.rowVersion())
                .executeUpdate();
        if (changed != 1) throw concurrentChange();
        return get(id);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetCategoryContracts.Category activate(UUID id, Long expectedVersion) {
        tx.bind();
        PaymentStyleHierarchyLock.lock(em);
        UUID actorId = authorization.requireActorId(FinanceAssetAuthorization.APPROVE);
        CategoryLock current = lock(id);
        if ("ACTIVE".equals(current.status())) return get(id);
        requireDraftAndVersion(current, expectedVersion);
        AssetCategoryContracts.Category category = get(id);
        if (category.effectiveFrom().isAfter(LocalDate.now(SHANGHAI))) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "未来生效的政策在生效日前须保持草稿状态");
        }
        List<String> missing = category.missingPolicyItems();
        if (!missing.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "会计政策字段不完整，请补齐：" + String.join("、", missing));
        }
        if ("DEFERRED_EXPENSE".equals(category.objectType()) && category.accumulatedStyleId() != null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "长期待摊费用政策不应使用累计折旧(备抵)科目");
        }
        requireDistinctAccounts(category);
        requirePostableStyle(category.costStyleId(), "成本科目", "ACCOUNT", "账户");
        if (category.accumulatedStyleId() != null) {
            requirePostableStyle(category.accumulatedStyleId(), "累计折旧科目", "ACCOUNT", "账户");
        }
        requirePostableStyle(category.expenseStyleId(), "费用科目", "EXPENSE", "费用");
        requirePostableStyle(category.clearingStyleId(), "清理科目", "ACCOUNT", "账户");
        em.createNativeQuery("""
                UPDATE finance_asset_categories
                SET status='INACTIVE', row_version=row_version+1,
                    updated_at=now(), updated_by=:actor
                WHERE object_type=:objectType AND code=:code AND status='ACTIVE'
                  AND id<>:id AND is_deleted=false
                """)
                .setParameter("actor", actorId)
                .setParameter("objectType", current.objectType())
                .setParameter("code", current.code())
                .setParameter("id", id)
                .executeUpdate();
        int changed = em.createNativeQuery("""
                UPDATE finance_asset_categories
                SET status='ACTIVE', row_version=row_version+1,
                    updated_at=now(), updated_by=:actor
                WHERE id=:id AND status='DRAFT' AND row_version=:version AND is_deleted=false
                """)
                .setParameter("actor", actorId)
                .setParameter("id", id)
                .setParameter("version", current.rowVersion())
                .executeUpdate();
        if (changed != 1) throw concurrentChange();
        return get(id);
    }

    @Transactional(readOnly = true)
    public AssetCategoryContracts.Category get(UUID id) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT id, object_type, code, name, version, status, effective_from,
                       default_method, default_months, default_salvage_rate,
                       cost_style_id, accumulated_style_id, expense_style_id, clearing_style_id,
                       required_document_codes::text, row_version
                FROM finance_asset_categories
                WHERE id=:id AND is_deleted=false
                """).setParameter("id", id).getResultList();
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "Asset category not found");
        return map(rows.getFirst());
    }

    private AssetCategoryContracts.Category map(Object[] row) {
        String objectType = text(row[1]);
        UUID cost = uuid(row[10]);
        UUID accumulated = uuid(row[11]);
        UUID expense = uuid(row[12]);
        UUID clearing = uuid(row[13]);
        String method = text(row[7]);
        Integer months = row[8] == null ? null : ((Number) row[8]).intValue();
        BigDecimal salvage = (BigDecimal) row[9];
        LocalDate effective = date(row[6]);
        var readiness = new AssetCategoryPolicyReadiness.Input(
                objectType, cost, accumulated, expense, clearing, method, months, salvage, effective);
        List<String> missing = AssetCategoryPolicyReadiness.missing(readiness);
        return new AssetCategoryContracts.Category(
                uuid(row[0]), objectType, text(row[2]), text(row[3]), ((Number) row[4]).intValue(),
                text(row[5]), effective, method, months, salvage,
                cost, accumulated, expense, clearing, strings(text(row[14])),
                missing.isEmpty(), missing, ((Number) row[15]).longValue());
    }

    private CategoryLock lock(UUID id) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT object_type, code, status, row_version
                FROM finance_asset_categories
                WHERE id=:id AND is_deleted=false
                FOR UPDATE
                """).setParameter("id", id).getResultList();
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "Asset category not found");
        Object[] row = rows.getFirst();
        return new CategoryLock(text(row[0]), text(row[1]), text(row[2]), ((Number) row[3]).longValue());
    }

    private static void requireDraftAndVersion(CategoryLock current, Long expectedVersion) {
        if (!"DRAFT".equals(current.status())) {
            throw new ApiException(ErrorCode.CONFLICT, "Only an unused DRAFT category version can change");
        }
        if (expectedVersion == null || current.rowVersion() != expectedVersion) throw concurrentChange();
    }

    private static String objectType(String value) {
        if (!"FIXED_ASSET".equals(value) && !"DEFERRED_EXPENSE".equals(value)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "objectType must be FIXED_ASSET or DEFERRED_EXPENSE");
        }
        return value;
    }

    private static String requiredText(String value, String field) {
        if (value == null || value.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, field + " is required");
        }
        return value.trim();
    }

    private static void requireDistinctAccounts(AssetCategoryContracts.Category category) {
        List<UUID> accounts = new ArrayList<>();
        accounts.add(category.costStyleId());
        if (category.accumulatedStyleId() != null) accounts.add(category.accumulatedStyleId());
        accounts.add(category.expenseStyleId());
        accounts.add(category.clearingStyleId());
        if (accounts.stream().distinct().count() != accounts.size()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "成本、累计折旧、费用与清理科目必须互不相同");
        }
    }

    private void requirePostableStyle(UUID styleId, String fieldLabel, String expectedCategory, String categoryLabel) {
        Number valid = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM payment_styles s
                WHERE s.id=:id AND s.is_deleted=false AND s.status='使用' AND s.category=:category
                  AND NOT EXISTS (
                      SELECT 1 FROM payment_styles child
                      WHERE child.parent_id=s.id AND child.is_deleted=false)
                """).setParameter("id", styleId).setParameter("category", expectedCategory).getSingleResult();
        if (valid.longValue() != 1) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    fieldLabel + " 须为在用且可过账的叶子" + categoryLabel);
        }
    }

    private String json(List<String> values) {
        try {
            List<String> clean = values == null ? List.of() : values.stream()
                    .map(String::trim).filter(value -> !value.isEmpty()).distinct().toList();
            return objectMapper.writeValueAsString(clean);
        } catch (JsonProcessingException exception) {
            throw new ApiException(ErrorCode.MALFORMED_REQUEST, "Invalid required document codes");
        }
    }

    private List<String> strings(String json) {
        try {
            return json == null ? List.of() : objectMapper.readValue(json, STRING_LIST);
        } catch (JsonProcessingException exception) {
            throw new ApiException(ErrorCode.INTERNAL, "Stored category policy is invalid");
        }
    }

    private static ApiException concurrentChange() {
        return new ApiException(ErrorCode.CONFLICT, "Asset category changed; refresh and retry");
    }

    private static UUID uuid(Object value) {
        return value == null ? null : value instanceof UUID id ? id : UUID.fromString(value.toString());
    }

    private static String text(Object value) {
        return value == null ? null : value.toString();
    }

    private static LocalDate date(Object value) {
        if (value == null) return null;
        return value instanceof LocalDate localDate ? localDate : ((Date) value).toLocalDate();
    }

    private record CategoryLock(String objectType, String code, String status, long rowVersion) {}
}
