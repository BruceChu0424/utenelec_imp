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
 * <p>Two managed numbering shapes coexist (2026-10-19, per user convention
 * "prefix + last two digits"):
 * <ul>
 *   <li><b>Short-managed</b> — a category with an explicit prefix numbers its
 *       records {@code prefix + 01..99, 100…}: the first free short suffix under
 *       the prefix is scanned (suffixes grow naturally past 99, matching the bulk
 *       renumber shape). The suffix lives in the code text only;
 *       {@code code_sequence} stays the globally unique identity counter. Editing
 *       the prefix renumbers the whole subtree from scratch in current code
 *       order (2026-10-19 用户口径「改前缀=全部重新来过」).</li>
 *   <li><b>Long-managed</b> — the fallback prefix (no explicit prefix up the
 *       tree) keeps the historical V258 shape: a single global sequence row per
 *       master type renders {@code prefix + %06d}, and the suffix value equals
 *       {@code code_sequence}.</li>
 * </ul>
 * A single sequence row still serializes create, update, move and category-wide
 * prefix changes. The nearest explicit category prefix wins; an empty prefix
 * inherits. V279 reserves normalized identifiers across business families for
 * life. V911 allows only a new goods UUID to acquire a proven unused, deleted
 * goods label through an append-only release ledger; all old UUIDs and claims
 * remain preserved and all other families keep their lifetime reservations.</p>
 */
@Service
@RequiredArgsConstructor
public class CategoryDrivenCodeService {

    private static final Pattern PREFIX = Pattern.compile("^[A-Z0-9]{1,8}$");
    private static final Pattern NUMERIC_SUFFIX = Pattern.compile("^[0-9]{2,18}$");
    private static final int MAX_GLOBAL_COLLISION_RETRIES = 1024;
    /** Short-managed allocation: two-digit suffixes 01..99, growing naturally to 100+. */
    private static final int SHORT_SUFFIX_WIDTH = 2;
    /** Short-managed allocation scan ceiling; renumbering may hand out more. */
    private static final int SHORT_SUFFIX_LIMIT = 9999;
    /** Suffixes at least this wide keep the V258 long-managed semantics (value == code_sequence). */
    private static final int LONG_SUFFIX_MIN_WIDTH = 6;

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
        return allocateNew(type, categoryId, requestedCode, null);
    }

    /** Only new goods UUIDs may acquire a proven unused, soft-deleted code. */
    @Transactional
    public CategoryCodeAllocation allocateForNewGoods(UUID categoryId, String requestedCode, UUID newGoodsId) {
        if (newGoodsId == null) throw new IllegalArgumentException("new goods UUID is required");
        return allocateNew(MasterType.GOODS, categoryId, requestedCode, newGoodsId);
    }

    private CategoryCodeAllocation allocateNew(MasterType type, UUID categoryId, String requestedCode, UUID newGoodsId) {
        requireType(type);
        lockSequence(type);
        EffectivePrefix effective = effectivePrefixOrFallback(type, categoryId);

        String requested = normalizeCode(requestedCode);
        if (requested == null) {
            if (effective.ownerCategoryId() != null) {
                // 显式前缀：短位受管——扫描首个可用短号（终身保留表兜底防重）；
                // 超过 99 自然进位到三位（与批量重排的增长口径一致）。
                for (int suffix = 1; suffix <= SHORT_SUFFIX_LIMIT; suffix++) {
                    String code = format(effective.prefix(), suffix, SHORT_SUFFIX_WIDTH);
                    if (availableForCreation(type, code, newGoodsId)) {
                        return new CategoryCodeAllocation(
                                code, nextSequenceLocked(type), effective.ownerCategoryId(), true);
                    }
                }
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "前缀 " + effective.prefix() + " 下可用的短编号已全部占用，"
                                + "请更换前缀或使用自定义编号");
            }
            for (int attempt = 0; attempt < MAX_GLOBAL_COLLISION_RETRIES; attempt++) {
                long sequence = nextSequenceLocked(type);
                String code = format(effective.prefix(), sequence, 6);
                if (availableForCreation(type, code, newGoodsId)) {
                    return new CategoryCodeAllocation(
                            code, sequence, effective.ownerCategoryId(), true);
                }
            }
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "连续编号已被历史全局编号占用，请检查编号冲突清单");
        }

        ManagedSuffix managed = parseManagedSuffix(effective.prefix(), requested);
        if (type == MasterType.GOODS && newGoodsId != null && codeUnavailable(type, requested, null)
                && Boolean.TRUE.equals(em.createNativeQuery("SELECT fn_claim_reusable_goods_code(:code,:id)")
                        .setParameter("code", requested).setParameter("id", newGoodsId).getSingleResult())) {
            // The old identity counter is never reused, including six-digit
            // historical display suffixes. Only the proven unused label moves.
            return new CategoryCodeAllocation(requested, nextSequenceLocked(type),
                    managed == null ? null : effective.ownerCategoryId(), managed != null);
        }
        if (managed != null) {
            if (managed.width() >= LONG_SUFFIX_MIN_WIDTH) {
                requireSequenceAvailable(type, managed.value(), null);
                requireCreationCodeAvailable(type, requested, newGoodsId);
                reserveSequenceLocked(type, managed.value());
                return new CategoryCodeAllocation(
                        requested, managed.value(), effective.ownerCategoryId(), true);
            }
            // 短位受管（前缀+2~5 位数字）：序号即编号文本后缀，身份序号另取全局值。
            requireCreationCodeAvailable(type, requested, newGoodsId);
            return new CategoryCodeAllocation(
                    requested, nextSequenceLocked(type), effective.ownerCategoryId(), true);
        }

        requireCreationCodeAvailable(type, requested, newGoodsId);
        long sequence = nextSequenceLocked(type);
        return new CategoryCodeAllocation(requested, sequence, null, false);
    }

    private boolean availableForCreation(MasterType type, String code, UUID newGoodsId) {
        if (!codeUnavailable(type, code, null)) return true;
        return type == MasterType.GOODS && newGoodsId != null && Boolean.TRUE.equals(em.createNativeQuery(
                "SELECT fn_claim_reusable_goods_code(:code,:id)")
                .setParameter("code", code).setParameter("id", newGoodsId).getSingleResult());
    }

    private void requireCreationCodeAvailable(MasterType type, String code, UUID newGoodsId) {
        if (!availableForCreation(type, code, newGoodsId)) {
            throw new ApiException(ErrorCode.CONFLICT, "编号已占用或缺少完整未使用证明，请使用其它编号");
        }
    }

    /**
     * Safely derives update metadata from the current persisted allocation.
     *
     * <ul>
     *   <li>A managed record with an unchanged/omitted code keeps its suffix
     *       (width preserved from the code text); moving category only recomputes
     *       the effective prefix and owner.  Pure-digit codes (numeric prefix +
     *       two-digit suffix) keep their text verbatim on a move.</li>
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
        return resolveUpdateAllocation(type, entityId, newCategoryId, requestedCode, current, true);
    }

    /** Read-only save preview; category moves use the writer's exact label and identity rules. */
    @Transactional(readOnly = true)
    public CategoryCodeAllocation previewForUpdate(
            MasterType type, UUID entityId, UUID newCategoryId, String requestedCode) {
        requireType(type);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("SELECT code,code_sequence,code_prefix_category_id,code_managed FROM "
                + type.table + " WHERE id=:id AND is_deleted=false")
                .setParameter("id", entityId).getResultList();
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "资料不存在，请刷新后重试");
        Object[] row = rows.getFirst();
        CategoryCodeAllocation current = new CategoryCodeAllocation((String) row[0], number(row[1]),
                (UUID) row[2], Boolean.TRUE.equals(row[3]));
        if (current.sequence() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "更新编号缺少当前记录元数据");
        }
        return resolveUpdateAllocation(type, entityId, newCategoryId, requestedCode, current, false);
    }

    private CategoryCodeAllocation resolveUpdateAllocation(
            MasterType type, UUID entityId, UUID newCategoryId, String requestedCode,
            CategoryCodeAllocation current, boolean reserveSequence) {
        EffectivePrefix effective = effectivePrefixOrFallback(type, newCategoryId);

        boolean explicitlyBlank = requestedCode != null && requestedCode.isBlank();
        String requested = normalizeCode(requestedCode);
        boolean unchanged = requested == null || requested.equals(normalizeCode(current.code()));

        if (unchanged && !explicitlyBlank) {
            if (!current.managed() && normalizeCode(current.code()) != null) {
                requireCodeAvailable(type, current.code(), entityId);
                return current;
            }
            String code = renderManaged(effective.prefix(), current.code(), current.sequence(), true);
            requireCodeAvailable(type, code, entityId);
            return new CategoryCodeAllocation(
                    code, current.sequence(), effective.ownerCategoryId(), true);
        }

        if (explicitlyBlank) {
            String code = renderManaged(effective.prefix(), current.code(), current.sequence(), false);
            requireCodeAvailable(type, code, entityId);
            return new CategoryCodeAllocation(
                    code, current.sequence(), effective.ownerCategoryId(), true);
        }

        ManagedSuffix managed = parseManagedSuffix(effective.prefix(), requested);
        if (managed != null) {
            if (managed.width() >= LONG_SUFFIX_MIN_WIDTH) {
                requireSequenceAvailable(type, managed.value(), entityId);
                requireCodeAvailable(type, requested, entityId);
                if (reserveSequence) reserveSequenceLocked(type, managed.value());
                return new CategoryCodeAllocation(
                        requested, managed.value(), effective.ownerCategoryId(), true);
            }
            requireCodeAvailable(type, requested, entityId);
            return new CategoryCodeAllocation(
                    requested, current.sequence(), effective.ownerCategoryId(), true);
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

    /** Read-only counterpart of the long-managed suffix guard used on save. */
    String requestedSequenceProblem(MasterType type, String requestedCode, UUID entityId, UUID categoryId) {
        // An unchanged label retains its persisted identity counter on update
        // and restore. A reused label can legitimately have another counter.
        if (entityId != null && Boolean.TRUE.equals(em.createNativeQuery(
                "SELECT EXISTS (SELECT 1 FROM " + type.table
                        + " WHERE id=:id AND upper(btrim(code))=upper(btrim(:code)))")
                .setParameter("id", entityId).setParameter("code", requestedCode).getSingleResult())) return null;
        if (type == MasterType.GOODS && entityId == null && em.createNativeQuery(
                "SELECT fn_goods_code_reusable_owner(:code)").setParameter("code", requestedCode)
                .getSingleResult() instanceof UUID) return null;
        String prefix = effectivePrefixOrFallback(type, categoryId).prefix();
        ManagedSuffix suffix = parseManagedSuffix(prefix, normalizeCode(requestedCode));
        if (suffix == null || suffix.width() < LONG_SUFFIX_MIN_WIDTH) return null;
        try {
            requireSequenceAvailable(type, suffix.value(), entityId);
            return null;
        } catch (ApiException conflict) {
            return conflict.getMessage();
        }
    }

    /**
     * Checks the same lifetime, exact-token ownership rule as
     * {@code fn_claim_global_business_prefix}, without claiming or locking anything.
     * Blank means inheritance and therefore creates no explicit prefix reservation.
     * An editing category may keep its current prefix, or reclaim a past prefix
     * that has no other owner; another category cannot reuse a deleted owner's prefix.
     */
    @Transactional(readOnly = true)
    public CategoryPrefixAvailability prefixAvailability(
            MasterType type, String requestedPrefix, UUID categoryId) {
        requireType(type);
        String normalized = normalizePrefix(requestedPrefix);
        String currentPrefix = null;
        if (categoryId != null) {
            requireCategory(type, categoryId);
            currentPrefix = explicitPrefix(type, categoryId);
        }
        if (normalized == null) {
            return new CategoryPrefixAvailability(null, true, null);
        }

        String ownerKey = categoryId == null ? "" : type.categoryTable + "/" + categoryId;
        Object value = em.createNativeQuery("""
                WITH members AS (
                    SELECT owner_kind, owner_key
                    FROM business_prefix_reservation_members
                    WHERE normalized_prefix = :prefix COLLATE "C")
                SELECT NOT EXISTS (SELECT 1 FROM members)
                    OR (EXISTS (
                            SELECT 1 FROM members
                            WHERE owner_kind = 'CATEGORY' AND owner_key = :ownerKey)
                        AND (:unchanged OR NOT EXISTS (
                            SELECT 1 FROM members
                            WHERE NOT (owner_kind = 'CATEGORY' AND owner_key = :ownerKey))))
                """)
                .setParameter("prefix", normalized)
                .setParameter("ownerKey", ownerKey)
                .setParameter("unchanged", normalized.equals(currentPrefix))
                .getSingleResult();
        boolean available = Boolean.TRUE.equals(value);
        return new CategoryPrefixAvailability(normalized, available,
                available ? null : CategoryPrefixAvailability.OCCUPIED_MESSAGE);
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
     * <p>Renumber shape (2026-10-19 用户口径「改前缀=全部重新来过」): when the resulting
     * effective prefix is <b>explicit</b>, every record in scope is renumbered from
     * scratch — {@code prefix + 01, 02, …} in current code order (suffixes grow
     * naturally past 99: 100, 101…); historical/custom codes are included.  When the
     * result falls back to the domain prefix (no explicit prefix anywhere), the
     * historical V258 shape is kept: {@code prefix + %06d(code_sequence)}.</p>
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
        int updated = updateFinalCodes(type, batchId, rootEffective.ownerCategoryId());
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
                    -- 窗口函数不许出现在 WHERE：先在内层算出 target_code，外层再比对。
                    SELECT master.id, master.code, master.code_managed,
                           master.code_sequence, master.code_prefix_category_id,
                           master.effective_prefix, master.effective_owner,
                           master.target_code
                    FROM (
                        SELECT master.id,
                               master.code,
                               master.code_managed,
                               master.code_sequence,
                               master.code_prefix_category_id,
                               scoped.effective_prefix,
                               scoped.effective_owner,
                               CASE
                                   WHEN scoped.effective_owner IS NOT NULL
                                       THEN scoped.effective_prefix
                                            || CASE WHEN row_number() OVER (
                                                         ORDER BY master.code, master.id) < 10
                                                    THEN '0' ELSE '' END
                                            || (row_number() OVER (
                                                         ORDER BY master.code, master.id))::text
                                   ELSE scoped.effective_prefix
                                        || repeat(
                                               '0',
                                               greatest(
                                                   6 - length(master.code_sequence::text),
                                                   0))
                                        || master.code_sequence::text
                               END AS target_code
                        FROM %s master
                        JOIN scoped ON scoped.id = master.category_id
                        JOIN candidate_ids ON candidate_ids.id = master.id
                    ) master
                    WHERE master.code IS DISTINCT FROM master.target_code
                       OR master.code_managed = false
                       OR master.code_prefix_category_id
                              IS DISTINCT FROM master.effective_owner
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
                SET code = '__MCB_' || CAST(:batchId AS text) || '_' || master.code || '_' || CAST(master.id AS text)
                FROM candidate
                WHERE master.id = candidate.id
                  AND master.code IS DISTINCT FROM candidate.target_code
                """.formatted(type.table),
                categoryId,
                resultingPrefix,
                resultingOwner)
                .setParameter("batchId", batchId)
                .executeUpdate();
    }

    private int updateFinalCodes(
            MasterType type,
            UUID batchId,
            UUID resultingOwner) {
        String versionUpdate = type.versioned ? ", version = master.version + 1" : "";
        // The first phase changes code and therefore its ordering. The history
        // inserted before that phase is the authoritative frozen assignment.
        return em.createNativeQuery("""
                UPDATE %s master
                SET code = history.new_code,
                    code_managed = true,
                    code_prefix_category_id = CAST(:owner AS uuid),
                    updated_at = now()
                    %s
                FROM master_code_history history
                WHERE history.batch_id = :batchId
                  AND history.master_type = :type
                  AND master.id = history.entity_id
                """.formatted(type.table, versionUpdate))
                .setParameter("owner", resultingOwner)
                .setParameter("batchId", batchId)
                .setParameter("type", type.name())
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

    /** A managed code's numeric suffix: value plus the width it was rendered with. */
    private record ManagedSuffix(long value, int width) {}

    private static ManagedSuffix parseManagedSuffix(String effectivePrefix, String code) {
        if (code == null || !code.startsWith(effectivePrefix)) {
            return null;
        }
        String suffix = code.substring(effectivePrefix.length());
        if (!NUMERIC_SUFFIX.matcher(suffix).matches()) {
            return null;
        }
        try {
            long value = Long.parseLong(suffix);
            return value > 0 ? new ManagedSuffix(value, suffix.length()) : null;
        } catch (NumberFormatException exception) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "编号数字部分超出支持范围");
        }
    }

    /**
     * Re-renders a managed code under [prefix], preserving the current code's own
     * suffix width.  Pure-digit codes (numeric prefix + short suffix) have no
     * splittable head: [keepPureDigits] keeps their text verbatim (an unchanged
     * code on a category move), while a blank opt-in re-renders them as
     * {@code prefix + %06d(sequence)}.  Codes without any 2-18 digit tail fall
     * back to the same long-managed rendering.
     */
    private static String renderManaged(String prefix, String currentCode, long sequence, boolean keepPureDigits) {
        ManagedSuffix exact = parseManagedSuffix(prefix, currentCode);
        if (exact != null) {
            return currentCode;
        }
        ManagedSuffix trailing = trailingManagedSuffix(currentCode);
        if (trailing != null) {
            return format(prefix, trailing.value(), trailing.width());
        }
        if (keepPureDigits && currentCode != null && currentCode.matches("[0-9]{2,18}")) {
            return currentCode;
        }
        return format(prefix, sequence, 6);
    }

    /** Greedy trailing 2-18 digit split with a non-empty non-digit head, else null. */
    private static ManagedSuffix trailingManagedSuffix(String code) {
        if (code == null) {
            return null;
        }
        int end = code.length();
        while (end > 0 && code.charAt(end - 1) >= '0' && code.charAt(end - 1) <= '9') {
            end--;
        }
        int width = code.length() - end;
        if (end == 0 || width < 2 || width > 18) {
            return null;
        }
        try {
            long value = Long.parseLong(code.substring(end));
            return value > 0 ? new ManagedSuffix(value, width) : null;
        } catch (NumberFormatException exception) {
            return null;
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
                    "编号前缀只可包含 1-8 位字母或数字，可用数字开头");
        }
        return prefix;
    }

    private static String normalizeCode(String raw) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        return raw.strip().toUpperCase(Locale.ROOT);
    }

    public static String format(String prefix, long sequence, int width) {
        if (prefix == null || sequence <= 0) {
            throw new IllegalArgumentException("prefix and positive sequence are required");
        }
        String digits = Long.toString(sequence);
        if (digits.length() < width) {
            digits = "0".repeat(width - digits.length()) + digits;
        }
        return prefix + digits;
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
