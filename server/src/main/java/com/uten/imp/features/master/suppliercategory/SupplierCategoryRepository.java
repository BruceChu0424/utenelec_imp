package com.uten.imp.features.master.suppliercategory;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface SupplierCategoryRepository extends JpaRepository<SupplierCategory, UUID> {

    /** 全树（未软删），按 id 升序保证父先于子（id 由老库迁移时已拓扑序写入）。 */
    List<SupplierCategory> findByDeletedFalseOrderById();

    /** 直接子分类（详情面板 childCount / 删除前置校验用）。 */
    List<SupplierCategory> findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(UUID parentId);

    /** 迁移/校验用：按老库主键反查。 */
    Optional<SupplierCategory> findByLegacyId(Integer legacyId);

    /** 递归 CTE：返回某分类及其全部后代（含自身），仅未软删，按 path 先序。 */
    @Query(value = """
            WITH RECURSIVE subtree AS (
                SELECT id FROM supplier_categories WHERE id = :rootId AND is_deleted = false
                UNION ALL
                SELECT c.id FROM supplier_categories c
                JOIN subtree s ON c.parent_id = s.id
                WHERE c.is_deleted = false
            )
            SELECT c.* FROM supplier_categories c
            WHERE c.id IN (SELECT id FROM subtree)
            ORDER BY c.path, c.sort_order
            """, nativeQuery = true)
    List<SupplierCategory> findSubtree(@Param("rootId") UUID rootId);

    /** 判断 candidate 是否为 root 的（含自身）后代——移动分类时防成环。 */
    @Query(value = """
            WITH RECURSIVE subtree AS (
                SELECT id FROM supplier_categories WHERE id = :rootId
                UNION ALL
                SELECT c.id FROM supplier_categories c JOIN subtree s ON c.parent_id = s.id
            )
            SELECT EXISTS(SELECT 1 FROM subtree WHERE id = :candidate)
            """, nativeQuery = true)
    boolean isDescendant(@Param("rootId") UUID rootId, @Param("candidate") UUID candidate);
}
