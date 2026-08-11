package com.uten.imp.features.master.paymentstyle;

import org.springframework.data.jpa.repository.JpaRepository;
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
                UNION ALL
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
                UNION ALL
                SELECT c.id FROM payment_styles c JOIN subtree s ON c.parent_id = s.id
            )
            SELECT EXISTS(SELECT 1 FROM subtree WHERE id = :candidate)
            """, nativeQuery = true)
    boolean isDescendant(@Param("rootId") UUID rootId, @Param("candidate") UUID candidate);
}
