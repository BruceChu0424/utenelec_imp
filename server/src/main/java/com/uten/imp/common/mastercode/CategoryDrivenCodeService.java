package com.uten.imp.common.mastercode;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Allocates mutable display codes while every relationship continues to use UUIDs.
 *
 * <p>The numeric suffix is global inside one master type.  A single sequence row
 * serializes create, update, move and category-wide prefix changes, so a prefix
 * change can preserve each record's suffix without colliding with another managed
 * record.  The nearest explicit category prefix wins; an empty prefix inherits.
 * V279 additionally reserves every normalized full identifier across all business
 * families for life, including deleted and historical values.</p>
 */
@Service
@RequiredArgsConstructor
public class CategoryDrivenCodeService {

    private static final Pattern PREFIX = Pattern.compile("^[A-Z][A-Z0-9]{0,7}$");
    private static final Pattern NUMERIC_SUFFIX = Pattern.compile("^[0-9]{6,18}$");
    private static final int MAX_GLOBAL_COLLISION_RETRIES = 1024;

    private final EntityManager em;

    public enum MasterType {
        GOODS("goods", "material_categories", "HP", true),
        MOULD("moulds", "mould_categories", "MJ", false),
        CLIENT("clients", "client_categories", "KH", true),
        SUPPLIER("suppliers", "supplier_categories", "GY", true);

        private final String table;
        private final String categoryTable;
        private final String fallbackPrefix;
        private final boolean versioned;

        MasterType(
                String table,
                String categoryTable,
                String fallbackPrefix,
                boolean versioned) {
            this.table = table;
            this.categoryTable = categoryTable;
            this.fallbackPrefix = fallbackPrefix;
            this.versioned = versioned;
        }
    }

    /** The category whose explicit prefix currently owns a resolved prefix; null means fallback. */
    public record EffectivePrefix(UUID categoryId, UUID ownerCategoryId, String prefix) {}

    /**
     * Allocates a code for a new record.  A null category is a supported ungrouped
     * master record and uses the domain fallback prefix with no prefix owner.
     */
    @Transactional
    public CategoryCodeAllocation allocate(MasterType type, UUID categoryId, String requestedCode) {
        requireType(type);
        lockSequence(type);
        EffectivePrefix effective = effectivePrefixOrFallback(type, categoryId);

        String requested = normalizeCode(requestedCode);
        if (requested == null) {
            for (int attempt = 0; attempt < MAX_GLOBAL_COLLISION_RETRIES; attempt++) {
                long sequence = nextSequenceLocked(type);
                String code = format(effective.prefix(), sequence);
                if (!codeUnavailable(type, code, null)) {
                    return new CategoryCodeAllocation(
                            code, sequence, effective.ownerCategoryId(), true);
                }
            }
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "连续编号已被历史全局编号占用，请检查编号冲突清单");
        }

        Long managedSequence = parseManagedSequence(effective.prefix(), requested);
        if (managedSequence != null) {
            requireSequenceAvailable(type, managedSequence, null);
            requireCodeAvailable(type, requested, null);
            reserveSequenceLocked(type, managedSequence);
            return new CategoryCodeAllocation(
                    requested, managedSequence, effective.ownerCategoryId(), true);
        }

        requireCodeAvailable(type, requested, null);
        long sequence = nextSequenceLocked(type);
        return new CategoryCodeAllocation(requested, sequence, null, false);
    }

    /**
     * Safely derives update metadata from the current persisted allocation.
     *
     * <ul>
     *   <li>A managed record with an unchanged/omitted code keeps its numeric suffix;
     *       moving category only recomputes the effective prefix and owner.</li>
     *   <li>An unmanaged record with an unchanged/omitted code keeps its custom code
     *       and stable internal sequence.</li>
     *   <li>An explicitly empty code opts into category-managed numbering while
     *       keeping the record's stable sequence.</li>
     *   <li>A different arbitrary code is custom/unmanaged.  A different code that
     *       exactly matches the effective prefix plus a free numeric suffix becomes
     *       managed and reserves that suffix.</li>
     * </ul>
     */
    @Transactional
    public CategoryCodeAllocation allocateForUpdate(
            MasterType type,
            UUID entityId,
            UUID newCategoryId,
            String requestedCode,
            CategoryCodeAllocation current) {
        requireType(type);
        if (entityId == null || current == null || current.sequence() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "更新编号缺少当前记录元数据");
        }

        lockSequence(type);
        EffectivePrefix effective = effectivePrefixOrFallback(type, newCategoryId);

        boolean explicitlyBlank = requestedCode != null && requestedCode.isBlank();
        String requested = normalizeCode(requestedCode);
        boolean unchanged = requested == null || requested.equals(normalizeCode(current.code()));

        if (unchanged && !explicitlyBlank) {
            if (!current.managed() && normalizeCode(current.code()) != null) {
                requireCodeAvailable(type, current.code(), entityId);
                return current;
            }
            String code = format(effective.prefix(), current.sequence());
            requireCodeAvailable(type, code, entityId);
            return new CategoryCodeAllocation(
                    code, current.sequence(), effective.ownerCategoryId(), true);
        }

        if (explicitlyBlank) {
            String code = format(effective.prefix(), current.sequence());
            requireCodeAvailable(type, code, entityId);
            return new CategoryCodeAllocation(
                    code, current.sequence(), effective.ownerCategoryId(), true);
        }

        Long managedSequence = parseManagedSequence(effective.prefix(), requested);
        if (managedSequence != null) {
            requireSequenceAvailable(type, managedSequence, entityId);
            requireCodeAvailable(type, requested, entityId);
            reserveSequenceLocked(type, managedSequence);
            return new CategoryCodeAllocation(
                    requested, managedSequence, effective.ownerCategoryId(), true);
        }

        requireCodeAvailable(type, requested, entityId);
        // A custom code does not need a new internal suffix: the existing globally
        // unique sequence is stable identity metadata, not a rendering of the text.
        return new CategoryCodeAllocation(requested, current.sequence(), null, false);
    }

    /** Resolves the nearest explicit prefix.  Public callers may also resolve null as fallback. */
    @Transactional(readOnly = true)
    public EffectivePrefix effectivePrefix(MasterType type, UUID categoryId) {
        requireType(type);
        return effectivePrefixOrFallback(type, categoryId);
    }

    /**
     * Previews an explicit prefix edit after (or immediately before) the category row
     * is changed.  A null/blank requested prefix means inherit the closest ancestor.
     */
    @Transactional(readOnly = true)
    public CategoryPrefixPreview preview(
            MasterType type, UUID categoryId, String requestedExplicitPrefix) {
        requireType(type);
        requireCategory(type, categoryId);

        return previewResolved(
                type, categoryId, requestedExplicitPrefix,
                inheritedPrefix(type, categoryId));
    }

    /**
     * Previews a prefix edit together with a category move.  The supplied parent is the
     * category's intended parent after save; null means a top-level category and therefore
     * inherits the master-domain fallback.  This prevents a parent move from silently
     * triggering a bulk renumber without the same impact preview used for prefix edits.
     */
    @Transactional(readOnly = true)
    public CategoryPrefixPreview previewForParent(
            MasterType type,
            UUID categoryId,
            String requestedExplicitPrefix,
            UUID requestedParentId) {
        requireType(type);
        requireCategory(type, categoryId);
        if (Objects.equals(categoryId, requestedParentId)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "上级分类不能是自身");
        }
        EffectivePrefix parentEffective = effectivePrefixOrFallback(type, requestedParentId);
        if (requestedParentId != null && isDescendantOrSelf(type, categoryId, requestedParentId)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "不能将分类移动到自身或其子分类下");
        }
        return previewResolved(
                type, categoryId, requestedExplicitPrefix,
                new PrefixResolution(
                        parentEffective.ownerCategoryId(), parentEffective.prefix()));
    }

    private CategoryPrefixPreview previewResolved(
            MasterType type,
            UUID categoryId,
            String requestedExplicitPrefix,
            PrefixResolution inherited) {

        String currentExplicit = explicitPrefix(type, categoryId);
        String requested = normalizePrefix(requestedExplicitPrefix);
        String resultingPrefix = requested == null ? inherited.prefix() : requested;
        UUID resultingOwner = requested == null ? inherited.ownerCategoryId() : categoryId;

        PreviewCounts counts = previewCounts(
                type, categoryId, resultingPrefix, resultingOwner);
        List<String> samples = conflictSamples(
                type, categoryId, resultingPrefix, resultingOwner);

        return new CategoryPrefixPreview(
                categoryId,
                currentExplicit,
                requested,
                resultingPrefix,
                counts.affectedRecords(),
                counts.customOrLegacyRecords(),
                counts.descendantOverrides(),
                counts.conflicts(),
                samples);
    }

    /**
     * Reconciles the subtree after the caller has saved/flushed its new parent and
     * explicit prefix.  {@code oldEffectivePrefix} is the effective prefix captured
     * before that category mutation; {@code newExplicitPrefix} is nullable and means
     * inheritance.  Descendant categories with their own prefix are never rewritten.
     *
     * <p>The active code uniqueness indexes are immediate, therefore a swap such as
     * A000001 -&gt; B000001 while B000001 is also moving is executed in two phases:
     * transaction-unique placeholders first, then final codes.  A logical history row
     * and lightweight audit pair preserve the real old/final codes.</p>
     */
    @Transactional
    public int reconcileSubtree(
            MasterType type,
            UUID categoryId,
            String oldEffectivePrefix,
            String newExplicitPrefix) {
        requireType(type);
        requireCategory(type, categoryId);
        String oldEffective = normalizePrefix(oldEffectivePrefix);
        if (oldEffective == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "修改分类前的有效编号前缀必填");
        }

        String expectedExplicit = normalizePrefix(newExplicitPrefix);
        lockSequence(type);
        String explicitNow = explicitPrefix(type, categoryId);
        if (!Objects.equals(explicitNow, expectedExplicit)) {
            throw new ApiException(ErrorCode.CONFLICT, "分类编号前缀已变化，请刷新后重试");
        }
        EffectivePrefix rootEffective = effectivePrefix(type, categoryId);
        UUID batchId = UUID.randomUUID();

        PreviewCounts counts = previewCounts(
                type, categoryId,
                rootEffective.prefix(), rootEffective.ownerCategoryId());
        if (counts.conflicts() > 0) {
            List<String> conflicts = conflictSamples(
                    type, categoryId,
                    rootEffective.prefix(), rootEffective.ownerCategoryId());
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "修改后编号与现有数据冲突：" + String.join("、", conflicts));
        }

        long affected = counts.affectedRecords();
        if (affected == 0) {
            insertBatch(type, batchId, categoryId, oldEffective, rootEffective.prefix(), 0);
            return 0;
        }

        insertBatch(
                type, batchId, categoryId, oldEffective,
                rootEffective.prefix(), affected);
        insertHistory(
                type, batchId, categoryId,
                rootEffective.prefix(), rootEffective.ownerCategoryId());

        setBatchAuditContext(batchId, "temporary");
        updateTemporaryCodes(
                type, batchId, categoryId,
                rootEffective.prefix(), rootEffective.ownerCategoryId());
        setBatchAuditContext(batchId, "final");
        int updated = updateFinalCodes(
                type, categoryId,
                rootEffective.prefix(), rootEffective.ownerCategoryId());
        clearBatchAuditContext();
        if (updated != affected) {
            throw new ApiException(ErrorCode.CONFLICT, "分类下编号数据已变化，请刷新后重试");
        }
        return updated;
    }

    private EffectivePrefix effectivePrefixOrFallback(MasterType type, UUID categoryId) {
        if (categoryId == null) {
            return new EffectivePrefix(null, null, type.fallbackPrefix);
        }
        Object[] row = (Object[]) em.createNativeQuery("""
                WITH RECURSIVE ancestors AS (
                    SELECT id, parent_id, code_prefix, is_deleted, 0 AS distance
                    FROM %s
                    WHERE id = :categoryId
                    UNION ALL
                    SELECT parent.id, parent.parent_id, parent.code_prefix,
                           parent.is_deleted, child.distance + 1
                    FROM %s parent
                    JOIN ancestors child ON child.parent_id = parent.id
                )
                SELECT EXISTS (
                           SELECT 1 FROM ancestors
                           WHERE distance = 0 AND is_deleted = false),
                       (SELECT id FROM ancestors
                        WHERE is_deleted = false
                          AND code_prefix IS NOT NULL
                          AND btrim(code_prefix) <> ''
                        ORDER BY distance LIMIT 1),
                       COALESCE(
                           (SELECT code_prefix FROM ancestors
                            WHERE is_deleted = false
                              AND code_prefix IS NOT NULL
                              AND btrim(code_prefix) <> ''
                            ORDER BY distance LIMIT 1),
                           :fallback)
                """.formatted(type.categoryTable, type.categoryTable))
                .setParameter("categoryId", categoryId)
                .setParameter("fallback", type.fallbackPrefix)
                .getSingleResult();
        if (!Boolean.TRUE.equals(row[0])) {
            throw new ApiException(ErrorCode.NOT_FOUND, "所属分类不存在");
        }
        UUID owner = row[1] == null ? null : (UUID) row[1];
        return new EffectivePrefix(categoryId, owner, normalizePrefix(String.valueOf(row[2])));
    }

    private void requireCategory(MasterType type, UUID categoryId) {
        if (categoryId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "所属分类必填");
        }
        Object exists = em.createNativeQuery("""
                SELECT EXISTS (
                    SELECT 1 FROM %s
                    WHERE id = :categoryId AND is_deleted = false)
                """.formatted(type.categoryTable))
                .setParameter("categoryId", categoryId)
                .getSingleResult();
        if (!Boolean.TRUE.equals(exists)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "所属分类不存在");
        }
    }

    private boolean isDescendantOrSelf(
            MasterType type, UUID categoryId, UUID requestedParentId) {
        Object value = em.createNativeQuery("""
                WITH RECURSIVE descendants AS (
                    SELECT id FROM %s
                    WHERE id = :categoryId AND is_deleted = false
                    UNION ALL
                    SELECT child.id
                    FROM %s child
                    JOIN descendants parent ON child.parent_id = parent.id
                    WHERE child.is_deleted = false)
                SELECT EXISTS (
                    SELECT 1 FROM descendants WHERE id = :requestedParentId)
                """.formatted(type.categoryTable, type.categoryTable))
                .setParameter("categoryId", categoryId)
                .setParameter("requestedParentId", requestedParentId)
                .getSingleResult();
        return Boolean.TRUE.equals(value);
    }

    private String explicitPrefix(MasterType type, UUID categoryId) {
        Object value = em.createNativeQuery("""
                SELECT COALESCE(code_prefix, '') FROM %s
                WHERE id = :categoryId AND is_deleted = false
                """.formatted(type.categoryTable))
                .setParameter("categoryId", categoryId)
                .getSingleResult();
        return normalizePrefix(String.valueOf(value));
    }

    private PrefixResolution inheritedPrefix(MasterType type, UUID categoryId) {
        Object[] row = (Object[]) em.createNativeQuery("""
                WITH RECURSIVE ancestors AS (
                    SELECT parent.id, parent.parent_id, parent.code_prefix,
                           parent.is_deleted, 0 AS distance
                    FROM %s child
                    JOIN %s parent ON parent.id = child.parent_id
                    WHERE child.id = :categoryId AND child.is_deleted = false
                    UNION ALL
                    SELECT parent.id, parent.parent_id, parent.code_prefix,
                           parent.is_deleted, child.distance + 1
                    FROM %s parent
                    JOIN ancestors child ON child.parent_id = parent.id
                )
                SELECT (SELECT id FROM ancestors
                        WHERE is_deleted = false
                          AND code_prefix IS NOT NULL AND btrim(code_prefix) <> ''
                        ORDER BY distance LIMIT 1),
                       COALESCE(
                           (SELECT code_prefix FROM ancestors
                            WHERE is_deleted = false
                              AND code_prefix IS NOT NULL AND btrim(code_prefix) <> ''
                            ORDER BY distance LIMIT 1),
                           :fallback)
                """.formatted(
                        type.categoryTable, type.categoryTable, type.categoryTable))
                .setParameter("categoryId", categoryId)
                .setParameter("fallback", type.fallbackPrefix)
                .getSingleResult();
        return new PrefixResolution(
                row[0] == null ? null : (UUID) row[0],
                normalizePrefix(String.valueOf(row[1])));
    }

    private PreviewCounts previewCounts(
            MasterType type,
            UUID categoryId,
            String resultingPrefix,
            UUID resultingOwner) {
        Object[] row = (Object[]) baseCandidateQuery(
                type,
                """
                SELECT count(*),
                       count(*) FILTER (WHERE candidate.code_managed = false),
                       (SELECT count(*) FROM scoped
                        WHERE id <> :root AND effective_owner = id),
                       count(*) FILTER (WHERE
                           EXISTS (
                               SELECT 1
                               FROM master_code_reservations reservation
                               WHERE reservation.master_domain = :masterDomain
                                 AND reservation.normalized_code =
                                         upper(btrim(candidate.target_code))
                                 AND NOT (
                                     EXISTS (
                                         SELECT 1
                                         FROM master_code_reservation_members member
                                         WHERE member.master_domain = reservation.master_domain
                                           AND member.normalized_code = reservation.normalized_code
                                           AND member.entity_id = candidate.id)
                                     AND (
                                         upper(btrim(candidate.code)) = reservation.normalized_code
                                         OR NOT EXISTS (
                                             SELECT 1
                                             FROM master_code_reservation_members other_member
                                             WHERE other_member.master_domain = reservation.master_domain
                                               AND other_member.normalized_code = reservation.normalized_code
                                               AND other_member.entity_id <> candidate.id))))
                           OR EXISTS (
                               SELECT 1
                               FROM business_identifier_reservations global_reservation
                               WHERE global_reservation.normalized_identifier =
                                         upper(btrim(candidate.target_code))
                                 AND NOT (
                                     EXISTS (
                                         SELECT 1
                                         FROM business_identifier_reservation_members member
                                         WHERE member.normalized_identifier =
                                                   global_reservation.normalized_identifier
                                           AND member.owner_domain = :masterDomain
                                           AND member.entity_id = candidate.id)
                                     AND (
                                         upper(btrim(candidate.code)) =
                                             global_reservation.normalized_identifier
                                         OR NOT EXISTS (
                                             SELECT 1
                                             FROM business_identifier_reservation_members other_member
                                             WHERE other_member.normalized_identifier =
                                                       global_reservation.normalized_identifier
                                               AND NOT (
                                                   other_member.owner_domain = :masterDomain
                                                   AND other_member.entity_id = candidate.id))))))
                FROM candidate
                """,
                categoryId,
                resultingPrefix,
                resultingOwner)
                .setParameter("masterDomain", type.name())
                .getSingleResult();
        return new PreviewCounts(
                number(row[0]), number(row[1]), number(row[2]), number(row[3]));
    }

    @SuppressWarnings("unchecked")
    private List<String> conflictSamples(
            MasterType type,
            UUID categoryId,
            String resultingPrefix,
            UUID resultingOwner) {
        return baseCandidateQuery(
                type,
                """
                SELECT DISTINCT candidate.target_code
                FROM candidate
                WHERE EXISTS (
                          SELECT 1
                          FROM master_code_reservations reservation
                          WHERE reservation.master_domain = :masterDomain
                            AND reservation.normalized_code = upper(btrim(candidate.target_code))
                            AND NOT (
                                EXISTS (
                                    SELECT 1
                                    FROM master_code_reservation_members member
                                    WHERE member.master_domain = reservation.master_domain
                                      AND member.normalized_code = reservation.normalized_code
                                      AND member.entity_id = candidate.id)
                                AND (
                                    upper(btrim(candidate.code)) = reservation.normalized_code
                                    OR NOT EXISTS (
                                        SELECT 1
                                        FROM master_code_reservation_members other_member
                                        WHERE other_member.master_domain = reservation.master_domain
                                          AND other_member.normalized_code = reservation.normalized_code
                                          AND other_member.entity_id <> candidate.id))))
                   OR EXISTS (
                          SELECT 1
                          FROM business_identifier_reservations global_reservation
                          WHERE global_reservation.normalized_identifier =
                                    upper(btrim(candidate.target_code))
                            AND NOT (
                                EXISTS (
                                    SELECT 1
                                    FROM business_identifier_reservation_members member
                                    WHERE member.normalized_identifier =
                                              global_reservation.normalized_identifier
                                      AND member.owner_domain = :masterDomain
                                      AND member.entity_id = candidate.id)
                                AND (
                                    upper(btrim(candidate.code)) =
                                        global_reservation.normalized_identifier
                                    OR NOT EXISTS (
                                        SELECT 1
                                        FROM business_identifier_reservation_members other_member
                                        WHERE other_member.normalized_identifier =
                                                  global_reservation.normalized_identifier
                                          AND NOT (
                                              other_member.owner_domain = :masterDomain
                                              AND other_member.entity_id = candidate.id)))))
                ORDER BY candidate.target_code
                LIMIT 5
                """,
                categoryId,
                resultingPrefix,
                resultingOwner)
                .setParameter("masterDomain", type.name())
                .getResultList();
    }

    private Query baseCandidateQuery(
            MasterType type,
            String terminalSql,
            UUID categoryId,
            String resultingPrefix,
            UUID resultingOwner) {
        String sql = """
                WITH RECURSIVE scoped AS (
                    SELECT category.id, category.parent_id,
                           CAST(:resultingPrefix AS text) AS effective_prefix,
                           CAST(NULLIF(:resultingOwner, '') AS uuid) AS effective_owner,
                           false AS blocked_by_descendant_override
                    FROM %s category
                    WHERE category.id = :root AND category.is_deleted = false
                    UNION ALL
                    SELECT child.id, child.parent_id,
                           CASE
                               WHEN child.code_prefix IS NOT NULL
                                AND btrim(child.code_prefix) <> ''
                               THEN child.code_prefix
                               ELSE parent.effective_prefix
                           END,
                           CASE
                               WHEN child.code_prefix IS NOT NULL
                                AND btrim(child.code_prefix) <> ''
                               THEN child.id
                               ELSE parent.effective_owner
                           END,
                           parent.blocked_by_descendant_override
                               OR (child.code_prefix IS NOT NULL
                                   AND btrim(child.code_prefix) <> '')
                    FROM %s child
                    JOIN scoped parent ON child.parent_id = parent.id
                    WHERE child.is_deleted = false
                ), candidate_ids AS (
                    SELECT master.id
                    FROM %s master
                    JOIN scoped ON scoped.id = master.category_id
                    WHERE master.is_deleted = false
                      AND scoped.blocked_by_descendant_override = false
                ), candidate AS (
                    SELECT master.id,
                           master.code,
                           master.code_managed,
                           master.code_sequence,
                           master.code_prefix_category_id,
                           scoped.effective_prefix,
                           scoped.effective_owner,
                           scoped.effective_prefix
                               || repeat(
                                      '0',
                                      greatest(
                                          6 - length(master.code_sequence::text),
                                          0))
                               || master.code_sequence::text AS target_code
                    FROM %s master
                    JOIN scoped ON scoped.id = master.category_id
                    JOIN candidate_ids ON candidate_ids.id = master.id
                    WHERE master.code IS DISTINCT FROM
                              scoped.effective_prefix
                                  || repeat(
                                         '0',
                                         greatest(
                                             6 - length(master.code_sequence::text),
                                             0))
                                  || master.code_sequence::text
                       OR master.code_managed = false
                       OR master.code_prefix_category_id
                              IS DISTINCT FROM scoped.effective_owner
                )
                """.formatted(
                type.categoryTable, type.categoryTable, type.table, type.table);
        Query query = em.createNativeQuery(sql + terminalSql)
                .setParameter("root", categoryId)
                .setParameter("resultingPrefix", resultingPrefix)
                .setParameter(
                        "resultingOwner",
                        resultingOwner == null ? "" : resultingOwner.toString());
        return query;
    }

    private void insertBatch(
            MasterType type,
            UUID batchId,
            UUID categoryId,
            String oldPrefix,
            String newPrefix,
            long affected) {
        em.createNativeQuery("""
                INSERT INTO master_code_change_batches (
                    id, master_type, category_id, old_prefix, new_prefix,
                    affected_count, created_by, request_id)
                VALUES (
                    :id, :type, :categoryId, :oldPrefix, :newPrefix, :affected,
                    NULLIF(current_setting('app.actor_id', true), '')::uuid,
                    NULLIF(current_setting('app.audit_request_id', true), '')::uuid)
                """)
                .setParameter("id", batchId)
                .setParameter("type", type.name())
                .setParameter("categoryId", categoryId)
                .setParameter("oldPrefix", oldPrefix)
                .setParameter("newPrefix", newPrefix)
                .setParameter("affected", affected)
                .executeUpdate();
    }

    private void insertHistory(
            MasterType type,
            UUID batchId,
            UUID categoryId,
            String resultingPrefix,
            UUID resultingOwner) {
        baseCandidateQuery(
                type,
                """
                INSERT INTO master_code_history (
                    batch_id, master_type, entity_id, old_code, new_code, reason,
                    changed_by, request_id)
                SELECT :batchId, :type, id, code, target_code,
                       'CATEGORY_PREFIX_CHANGE',
                       NULLIF(current_setting('app.actor_id', true), '')::uuid,
                       NULLIF(current_setting('app.audit_request_id', true), '')::uuid
                FROM candidate
                """,
                categoryId,
                resultingPrefix,
                resultingOwner)
                .setParameter("batchId", batchId)
                .setParameter("type", type.name())
                .executeUpdate();
    }

    private void updateTemporaryCodes(
            MasterType type,
            UUID batchId,
            UUID categoryId,
            String resultingPrefix,
            UUID resultingOwner) {
        baseCandidateQuery(
                type,
                """
                UPDATE %s master
                SET code = '__MCB_' || CAST(:batchId AS text) || '_' || CAST(candidate.id AS text)
                FROM candidate
                WHERE master.id = candidate.id
                """.formatted(type.table),
                categoryId,
                resultingPrefix,
                resultingOwner)
                .setParameter("batchId", batchId)
                .executeUpdate();
    }

    private int updateFinalCodes(
            MasterType type,
            UUID categoryId,
            String resultingPrefix,
            UUID resultingOwner) {
        String versionUpdate = type.versioned ? ", version = master.version + 1" : "";
        return baseCandidateQuery(
                type,
                """
                UPDATE %s master
                SET code = candidate.target_code,
                    code_managed = true,
                    code_prefix_category_id = candidate.effective_owner,
                    updated_at = now()
                    %s
                FROM candidate
                WHERE master.id = candidate.id
                """.formatted(type.table, versionUpdate),
                categoryId,
                resultingPrefix,
                resultingOwner)
                .executeUpdate();
    }

    private void setBatchAuditContext(UUID batchId, String stage) {
        em.createNativeQuery("SELECT set_config('app.master_code_batch_id', :batchId, true)")
                .setParameter("batchId", batchId.toString())
                .getSingleResult();
        em.createNativeQuery("SELECT set_config('app.master_code_audit_stage', :stage, true)")
                .setParameter("stage", stage)
                .getSingleResult();
    }

    private void clearBatchAuditContext() {
        em.createNativeQuery("SELECT set_config('app.master_code_batch_id', '', true)")
                .getSingleResult();
        em.createNativeQuery("SELECT set_config('app.master_code_audit_stage', '', true)")
                .getSingleResult();
    }

    private long nextSequenceLocked(MasterType type) {
        Object row = em.createNativeQuery("""
                UPDATE category_master_code_sequences
                SET last_seq = last_seq + 1
                WHERE master_type = :type
                RETURNING last_seq
                """)
                .setParameter("type", type.name())
                .getSingleResult();
        return scalarLong(row);
    }

    private void reserveSequenceLocked(MasterType type, long requested) {
        if (requested <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "编号数字部分必须大于 0");
        }
        em.createNativeQuery("""
                UPDATE category_master_code_sequences
                SET last_seq = greatest(last_seq, :requested)
                WHERE master_type = :type
                """)
                .setParameter("type", type.name())
                .setParameter("requested", requested)
                .executeUpdate();
    }

    private void lockSequence(MasterType type) {
        List<?> rows = em.createNativeQuery("""
                SELECT last_seq
                FROM category_master_code_sequences
                WHERE master_type = :type
                FOR UPDATE
                """)
                .setParameter("type", type.name())
                .getResultList();
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.INTERNAL, "主档编号序列未初始化");
        }
    }

    private void requireCodeAvailable(MasterType type, String code, UUID excludedId) {
        if (codeUnavailable(type, code, excludedId)) {
            throw new ApiException(ErrorCode.CONFLICT, "编号已存在：" + code);
        }
    }

    private boolean codeUnavailable(MasterType type, String code, UUID excludedId) {
        String existingOwnerAllowance = excludedId == null ? "" : """
                AND NOT (
                    EXISTS (
                        SELECT 1
                        FROM master_code_reservation_members member
                        WHERE member.master_domain = reservation.master_domain
                          AND member.normalized_code = reservation.normalized_code
                          AND member.entity_id = :excludedId)
                    AND (
                        EXISTS (
                            SELECT 1 FROM %s current_master
                            WHERE current_master.id = :excludedId
                              AND upper(btrim(current_master.code)) =
                                      reservation.normalized_code)
                        OR NOT EXISTS (
                            SELECT 1
                            FROM master_code_reservation_members other_member
                            WHERE other_member.master_domain = reservation.master_domain
                              AND other_member.normalized_code = reservation.normalized_code
                              AND other_member.entity_id <> :excludedId)))
                """.formatted(type.table);
        String globalOwnerAllowance = excludedId == null ? "" : """
                AND NOT (
                    EXISTS (
                        SELECT 1
                        FROM business_identifier_reservation_members member
                        WHERE member.normalized_identifier =
                                  global_reservation.normalized_identifier
                          AND member.owner_domain = :masterDomain
                          AND member.entity_id = :excludedId)
                    AND (
                        EXISTS (
                            SELECT 1 FROM %s current_master
                            WHERE current_master.id = :excludedId
                              AND upper(btrim(current_master.code)) =
                                      global_reservation.normalized_identifier)
                        OR NOT EXISTS (
                            SELECT 1
                            FROM business_identifier_reservation_members other_member
                            WHERE other_member.normalized_identifier =
                                      global_reservation.normalized_identifier
                              AND NOT (
                                  other_member.owner_domain = :masterDomain
                                  AND other_member.entity_id = :excludedId))))
                """.formatted(type.table);
        Query query = em.createNativeQuery("""
                SELECT EXISTS (
                           SELECT 1
                           FROM master_code_reservations reservation
                           WHERE reservation.master_domain = :masterDomain
                             AND reservation.normalized_code = upper(btrim(:code))
                             %s)
                    OR EXISTS (
                           SELECT 1
                           FROM business_identifier_reservations global_reservation
                           WHERE global_reservation.normalized_identifier =
                                     upper(btrim(:code))
                             %s)
                """.formatted(existingOwnerAllowance, globalOwnerAllowance))
                .setParameter("masterDomain", type.name())
                .setParameter("code", code);
        if (excludedId != null) {
            query.setParameter("excludedId", excludedId);
        }
        Object exists = query.getSingleResult();
        return Boolean.TRUE.equals(exists);
    }

    private void requireSequenceAvailable(MasterType type, long sequence, UUID excludedId) {
        String exclusion = excludedId == null ? "" : " AND id <> :excludedId";
        Query query = em.createNativeQuery("""
                SELECT EXISTS (
                    SELECT 1 FROM %s
                    WHERE code_sequence = :sequence%s)
                """.formatted(type.table, exclusion))
                .setParameter("sequence", sequence);
        if (excludedId != null) {
            query.setParameter("excludedId", excludedId);
        }
        Object exists = query.getSingleResult();
        if (Boolean.TRUE.equals(exists)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "编号数字序号已被使用：" + sequence);
        }
    }

    private static Long parseManagedSequence(String effectivePrefix, String code) {
        if (code == null || !code.startsWith(effectivePrefix)) {
            return null;
        }
        String suffix = code.substring(effectivePrefix.length());
        if (!NUMERIC_SUFFIX.matcher(suffix).matches()) {
            return null;
        }
        try {
            long value = Long.parseLong(suffix);
            return value > 0 ? value : null;
        } catch (NumberFormatException exception) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "编号数字部分超出支持范围");
        }
    }

    public static String normalizePrefix(String raw) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        String prefix = raw.strip().toUpperCase(Locale.ROOT);
        if (!PREFIX.matcher(prefix).matches()) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "编号前缀须以字母开头，只可包含 1-8 位大写字母或数字");
        }
        return prefix;
    }

    private static String normalizeCode(String raw) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        return raw.strip().toUpperCase(Locale.ROOT);
    }

    public static String format(String prefix, long sequence) {
        if (prefix == null || sequence <= 0) {
            throw new IllegalArgumentException("prefix and positive sequence are required");
        }
        return prefix + String.format(Locale.ROOT, "%06d", sequence);
    }

    private static void requireType(MasterType type) {
        if (type == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "主档类型必填");
        }
    }

    private static long scalarLong(Object row) {
        Object scalar = row instanceof Object[] array ? array[0] : row;
        return ((Number) scalar).longValue();
    }

    private static long number(Object value) {
        return value == null ? 0L : ((Number) value).longValue();
    }

    private record PrefixResolution(UUID ownerCategoryId, String prefix) {}

    private record PreviewCounts(
            long affectedRecords,
            long customOrLegacyRecords,
            long descendantOverrides,
            long conflicts) {}

}
