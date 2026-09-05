package com.uten.imp.features.master.materialcategory;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.OffsetDateTime;
import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface MaterialCategoryRepository extends JpaRepository<MaterialCategory, UUID> {

    /** 全树（未软删）；按 sort_order、name 升序决定同级显示顺序（buildTree 两段式装配，不依赖此处顺序保证父子关系）。 */
    List<MaterialCategory> findByDeletedFalseOrderBySortOrderAscNameAsc();

    /** 直接子分类（详情面板 childCount / 删除前置校验用）。 */
    List<MaterialCategory> findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(UUID parentId);

    /** 迁移/校验用：按老库主键反查。 */
    Optional<MaterialCategory> findByLegacyId(Integer legacyId);

    /**
     * 旧兼容辅助查询：仅检查当前未软删行。分类 code 已改为服务端生成；跨域、历史及软删后的
     * 终身占号由 V279 全局预约表/触发器权威保证，不能用本方法代替。
     */
    boolean existsByCodeAndDeletedFalse(String code);

    /** 递归 CTE：返回某分类及其全部后代（含自身），仅未软删，按 path 先序。 */
    @Query(value = """
            WITH RECURSIVE subtree AS (
                SELECT id FROM material_categories WHERE id = :rootId AND is_deleted = false
                UNION ALL
                SELECT c.id FROM material_categories c
                JOIN subtree s ON c.parent_id = s.id
                WHERE c.is_deleted = false
            )
            SELECT c.* FROM material_categories c
            WHERE c.id IN (SELECT id FROM subtree)
            ORDER BY c.path, c.sort_order
            """, nativeQuery = true)
    List<MaterialCategory> findSubtree(@Param("rootId") UUID rootId);

    /** 判断 candidate 是否为 root 的（含自身）后代——移动分类时防成环。 */
    @Query(value = """
            WITH RECURSIVE subtree AS (
                SELECT id FROM material_categories WHERE id = :rootId
                UNION ALL
                SELECT c.id FROM material_categories c JOIN subtree s ON c.parent_id = s.id
            )
            SELECT EXISTS(SELECT 1 FROM subtree WHERE id = :candidate)
            """, nativeQuery = true)
    boolean isDescendant(@Param("rootId") UUID rootId, @Param("candidate") UUID candidate);

    /**
     * 按当前 parent_id 一次性重建移动子树的真实深度和物化路径。
     * 不依赖移动前的旧 path 排序；visited 避免异常环导致无限递归。
     */
    @Modifying(flushAutomatically = true, clearAutomatically = true)
    @Query(value = """
            WITH RECURSIVE rebuilt(id, new_level, new_path, visited) AS (
                SELECT c.id,
                       CASE WHEN parent.id IS NULL THEN 0 ELSE parent.level + 1 END,
                       CASE
                           WHEN parent.id IS NULL THEN '/' || c.code || '/'
                           ELSE COALESCE(parent.path, '/') || c.code || '/'
                       END::text,
                       ARRAY[c.id]
                FROM material_categories c
                LEFT JOIN material_categories parent ON c.parent_id = parent.id
                WHERE c.id = :rootId AND c.is_deleted = false
                UNION ALL
                SELECT child.id,
                       parent.new_level + 1,
                       (parent.new_path || child.code || '/')::text,
                       parent.visited || child.id
                FROM material_categories child
                JOIN rebuilt parent ON child.parent_id = parent.id
                WHERE NOT child.id = ANY(parent.visited)
            )
            UPDATE material_categories c
            SET level = rebuilt.new_level,
                path = rebuilt.new_path,
                updated_at = now(),
                updated_by = COALESCE(
                    NULLIF(current_setting('app.actor_id', true), '')::uuid,
                    c.updated_by)
            FROM rebuilt
            WHERE c.id = rebuilt.id
            """, nativeQuery = true)
    int rebuildSubtreeHierarchy(@Param("rootId") UUID rootId);

    /** 子树（含给定分类及其全部后代）下、未软删的货品数。删除前预警 + 级联软删范围评估用。
     *  原生查询：goods.category_id 走 UUID，IN 集合由调用方从 findSubtree 收集。 */
    @Query(value = """
            SELECT count(*) FROM goods
            WHERE is_deleted = false AND category_id IN (:ids)
            """, nativeQuery = true)
    long countGoodsByCategoryIds(@Param("ids") Collection<UUID> ids);

    /** 每个分类的直接（非子树）未软删货品数：树端点 withGoodsCounts 用，Java 端后序累加成子树数。
     *  返回行 [category_id uuid, count bigint]；无货品的分类不出现。 */
    @Query(value = """
            SELECT category_id, count(*) FROM goods
            WHERE is_deleted = false AND category_id IS NOT NULL
            GROUP BY category_id
            """, nativeQuery = true)
    List<Object[]> countGoodsPerCategory();

    /** 批量软删子树下货品：is_deleted=true + deleted_at 戳。单据/报表 JOIN goods 仅按 id 关联、
     *  不过滤 is_deleted，故历史单据货品名仍可解析；软删只是把它们从货品资料页/选择器隐藏。 */
    @Query(value = """
            UPDATE goods SET is_deleted = true, deleted_at = :now
            WHERE is_deleted = false AND category_id IN (:ids)
            """, nativeQuery = true)
    @Modifying
    int softDeleteGoodsByCategoryIds(@Param("ids") Collection<UUID> ids, @Param("now") OffsetDateTime now);
}
