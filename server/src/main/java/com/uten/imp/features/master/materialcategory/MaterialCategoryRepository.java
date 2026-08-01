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

    /** 全树（未软删），按 id 升序保证父先于子（id 由老库迁移时已拓扑序写入）。 */
    List<MaterialCategory> findByDeletedFalseOrderById();

    /** 直接子分类（详情面板 childCount / 删除前置校验用）。 */
    List<MaterialCategory> findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(UUID parentId);

    /** 迁移/校验用：按老库主键反查。 */
    Optional<MaterialCategory> findByLegacyId(Integer legacyId);

    /** 自定义编码查重（仅未软删）。注意：历史数据有大量重复 code（见 V31），
     *  此查询只用于拦截「新建/改码时与现存 code 冲突」，不改变历史重复码。 */
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

    /** 子树（含给定分类及其全部后代）下、未软删的货品数。删除前预警 + 级联软删范围评估用。
     *  原生查询：goods.category_id 走 UUID，IN 集合由调用方从 findSubtree 收集。 */
    @Query(value = """
            SELECT count(*) FROM goods
            WHERE is_deleted = false AND category_id IN (:ids)
            """, nativeQuery = true)
    long countGoodsByCategoryIds(@Param("ids") Collection<UUID> ids);

    /** 批量软删子树下货品：is_deleted=true + deleted_at 戳。单据/报表 JOIN goods 仅按 id 关联、
     *  不过滤 is_deleted，故历史单据货品名仍可解析；软删只是把它们从货品资料页/选择器隐藏。 */
    @Query(value = """
            UPDATE goods SET is_deleted = true, deleted_at = :now
            WHERE is_deleted = false AND category_id IN (:ids)
            """, nativeQuery = true)
    @Modifying
    int softDeleteGoodsByCategoryIds(@Param("ids") Collection<UUID> ids, @Param("now") OffsetDateTime now);
}
