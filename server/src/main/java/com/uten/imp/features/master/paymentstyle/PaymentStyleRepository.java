package com.uten.imp.features.master.paymentstyle;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * 收付款类别仓库。范式同 {@code MaterialCategoryRepository}（邻接表 + 物化路径）。
 */
public interface PaymentStyleRepository extends JpaRepository<PaymentStyle, UUID> {

    /** 全树（未软删）；按 sort_order、name 升序决定同级显示顺序（buildTree 两段式装配，不依赖此处顺序保证父子关系）。 */
    List<PaymentStyle> findByDeletedFalseOrderBySortOrderAscNameAsc();

    /** 直接子节点（详情面板 childCount / 删除前置校验用）。 */
    List<PaymentStyle> findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(UUID parentId);

    /** 按大类过滤（树视图分组用）。 */
    List<PaymentStyle> findByCategoryAndDeletedFalseOrderBySortOrderAscNameAsc(String category);

    /** 迁移/校验用：按老库主键反查。 */
    Optional<PaymentStyle> findByLegacyId(Integer legacyId);

    /** 递归 CTE：返回某节点及其全部后代（含自身），仅未软删，按 path 先序。 */
    @Query(value = """
            WITH RECURSIVE subtree AS (
                SELECT id FROM payment_styles WHERE id = :rootId AND is_deleted = false
                UNION
                SELECT c.id FROM payment_styles c
                JOIN subtree s ON c.parent_id = s.id
                WHERE c.is_deleted = false
            )
            SELECT c.* FROM payment_styles c
            WHERE c.id IN (SELECT id FROM subtree)
            ORDER BY c.path, c.sort_order
            """, nativeQuery = true)
    List<PaymentStyle> findSubtree(@Param("rootId") UUID rootId);

    /** 判断 candidate 是否为 root 的（含自身）后代——移动节点时防成环。 */
    @Query(value = """
            WITH RECURSIVE subtree AS (
                SELECT id FROM payment_styles WHERE id = :rootId
                UNION
                SELECT c.id FROM payment_styles c JOIN subtree s ON c.parent_id = s.id
            )
            SELECT EXISTS(SELECT 1 FROM subtree WHERE id = :candidate)
            """, nativeQuery = true)
    boolean isDescendant(@Param("rootId") UUID rootId, @Param("candidate") UUID candidate);

    /**
     * 按当前 parent_id 原子重建移动子树的 level/path 和审计更新时间。
     * 不依赖移动前的旧 path 排序；visited 避免异常环导致无限递归。
     */
    @Modifying(flushAutomatically = true, clearAutomatically = true)
    @Query(value = """
            WITH RECURSIVE rebuilt(id, new_level, new_path, visited) AS (
                SELECT style.id,
                       CASE WHEN parent.id IS NULL THEN 0 ELSE parent.level + 1 END,
                       CASE
                           WHEN parent.id IS NULL THEN '/' || style.code || '/'
                           ELSE COALESCE(parent.path, '/') || style.code || '/'
                       END::text,
                       ARRAY[style.id]
                FROM payment_styles style
                LEFT JOIN payment_styles parent ON style.parent_id = parent.id
                WHERE style.id = :rootId AND style.is_deleted = false
                UNION ALL
                SELECT child.id,
                       parent.new_level + 1,
                       (parent.new_path || child.code || '/')::text,
                       parent.visited || child.id
                FROM payment_styles child
                JOIN rebuilt parent ON child.parent_id = parent.id
                WHERE NOT child.id = ANY(parent.visited)
            )
            UPDATE payment_styles style
            SET level = rebuilt.new_level,
                path = rebuilt.new_path,
                updated_at = now(),
                updated_by = COALESCE(
                    NULLIF(current_setting('app.actor_id', true), '')::uuid,
                    style.updated_by)
            FROM rebuilt
            WHERE style.id = rebuilt.id
            """, nativeQuery = true)
    int rebuildSubtreeHierarchy(@Param("rootId") UUID rootId);

    /**
     * 检查给定节点（可选整棵子树）的全部现存外部 UUID FK。
     * 删除叶节点、判断目标叶子能否变目录、移动子树共用；
     * 历史/软删业务行也属于审计链，因此不按其 is_deleted 过滤。
     */
    @Query(value = """
            WITH RECURSIVE style_subtree(id, visited) AS (
                SELECT id, ARRAY[id]
                FROM payment_styles
                WHERE id = :rootId
                UNION ALL
                SELECT child.id, parent.visited || child.id
                FROM payment_styles child
                JOIN style_subtree parent ON child.parent_id = parent.id
                WHERE :includeDescendants
                  AND NOT child.id = ANY(parent.visited)
            )
            SELECT EXISTS (
                SELECT 1
                FROM (
                    SELECT 1 AS hit FROM gl_entries
                    WHERE style_id IN (SELECT id FROM style_subtree)
                    UNION ALL
                    SELECT 1 FROM fixed_assets
                    WHERE expense_style_id IN (SELECT id FROM style_subtree)
                       OR cost_style_snapshot_id IN (SELECT id FROM style_subtree)
                       OR accumulated_style_snapshot_id IN (SELECT id FROM style_subtree)
                       OR expense_style_snapshot_id IN (SELECT id FROM style_subtree)
                       OR clearing_style_snapshot_id IN (SELECT id FROM style_subtree)
                    UNION ALL
                    SELECT 1 FROM deferred_expenses
                    WHERE expense_style_id IN (SELECT id FROM style_subtree)
                       OR cost_style_snapshot_id IN (SELECT id FROM style_subtree)
                       OR accumulated_style_snapshot_id IN (SELECT id FROM style_subtree)
                       OR expense_style_snapshot_id IN (SELECT id FROM style_subtree)
                       OR clearing_style_snapshot_id IN (SELECT id FROM style_subtree)
                    UNION ALL
                    SELECT 1 FROM expense_claims
                    WHERE payment_expense_style_id IN (SELECT id FROM style_subtree)
                    UNION ALL
                    SELECT 1 FROM finance_asset_categories
                    WHERE cost_style_id IN (SELECT id FROM style_subtree)
                       OR accumulated_style_id IN (SELECT id FROM style_subtree)
                       OR expense_style_id IN (SELECT id FROM style_subtree)
                       OR clearing_style_id IN (SELECT id FROM style_subtree)
                    UNION ALL
                    SELECT 1 FROM finance_asset_books
                    WHERE cost_style_id IN (SELECT id FROM style_subtree)
                       OR accumulated_style_id IN (SELECT id FROM style_subtree)
                       OR expense_style_id IN (SELECT id FROM style_subtree)
                       OR clearing_style_id IN (SELECT id FROM style_subtree)
                    UNION ALL
                    SELECT 1 FROM finance_deferral_schedule_versions
                    WHERE expense_style_id IN (SELECT id FROM style_subtree)
                       OR cost_style_id IN (SELECT id FROM style_subtree)
                       OR clearing_style_id IN (SELECT id FROM style_subtree)
                    UNION ALL
                    SELECT 1 FROM finance_asset_posting_lines
                    WHERE cost_style_id IN (SELECT id FROM style_subtree)
                       OR accumulated_style_id IN (SELECT id FROM style_subtree)
                       OR expense_style_id IN (SELECT id FROM style_subtree)
                       OR clearing_style_id IN (SELECT id FROM style_subtree)
                    UNION ALL
                    SELECT 1 FROM finance_receipts
                    WHERE other_fee_style_id IN (SELECT id FROM style_subtree)
                    UNION ALL
                    SELECT 1 FROM finance_expense_items
                    WHERE expense_style_id IN (SELECT id FROM style_subtree)
                    UNION ALL
                    SELECT 1 FROM finance_other_income_items
                    WHERE income_style_id IN (SELECT id FROM style_subtree)
                    UNION ALL
                    SELECT 1 FROM accounts
                    WHERE style_id IN (SELECT id FROM style_subtree)
                ) business_reference
                LIMIT 1
            )
            """, nativeQuery = true)
    boolean hasBusinessReferences(
            @Param("rootId") UUID rootId,
            @Param("includeDescendants") boolean includeDescendants);

    /**
     * 当前节点或子树是否仍被“使用中、未删除”的账户引用。停用类别时使用；
     * 已停用/已删除账户属于历史身份，不阻止普通类别后续停用。
     */
    @Query(value = """
            WITH RECURSIVE style_subtree(id, visited) AS (
                SELECT id, ARRAY[id]
                FROM payment_styles
                WHERE id = :rootId AND COALESCE(is_deleted, FALSE) = FALSE
                UNION ALL
                SELECT child.id, parent.visited || child.id
                FROM payment_styles child
                JOIN style_subtree parent ON child.parent_id = parent.id
                WHERE COALESCE(child.is_deleted, FALSE) = FALSE
                  AND NOT child.id = ANY(parent.visited)
            )
            SELECT EXISTS (
                SELECT 1
                FROM accounts account
                WHERE COALESCE(account.is_deleted, FALSE) = FALSE
                  AND account.status = '使用'
                  AND account.style_id IN (SELECT id FROM style_subtree)
            )
            """, nativeQuery = true)
    boolean hasActiveAccountReferences(@Param("rootId") UUID rootId);
}
