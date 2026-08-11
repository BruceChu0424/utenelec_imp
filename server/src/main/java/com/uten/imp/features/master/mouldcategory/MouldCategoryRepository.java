package com.uten.imp.features.master.mouldcategory;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * 模具分类仓库。查询方法与 {@code MaterialCategoryRepository} 一一对应（表名换 mould_categories）。
 */
public interface MouldCategoryRepository extends JpaRepository<MouldCategory, UUID> {

    /** 全树（未软删）；按 sort_order、name 升序决定同级显示顺序（buildTree 两段式装配，不依赖此处顺序保证父子关系）。 */
    List<MouldCategory> findByDeletedFalseOrderBySortOrderAscNameAsc();

    /** 直接子分类（详情面板 childCount / 删除前置校验用）。 */
    List<MouldCategory> findByParentIdAndDeletedFalseOrderBySortOrderAscNameAsc(UUID parentId);

    /** 迁移/校验用：按老库主键反查。 */
    Optional<MouldCategory> findByLegacyId(Integer legacyId);

    /** 自定义编码查重（仅未软删）。历史重复码不拦截，仅「新建时与现存 code 冲突」。 */
    boolean existsByCodeAndDeletedFalse(String code);

    /** 递归 CTE：返回某分类及其全部后代（含自身），仅未软删，按 path 先序。 */
    @Query(value = """
            WITH RECURSIVE subtree AS (
                SELECT id FROM mould_categories WHERE id = :rootId AND is_deleted = false
                UNION ALL
                SELECT c.id FROM mould_categories c
                JOIN subtree s ON c.parent_id = s.id
                WHERE c.is_deleted = false
            )
            SELECT c.* FROM mould_categories c
            WHERE c.id IN (SELECT id FROM subtree)
            ORDER BY c.path, c.sort_order
            """, nativeQuery = true)
    List<MouldCategory> findSubtree(@Param("rootId") UUID rootId);

    /** 判断 candidate 是否为 root 的（含自身）后代——移动分类时防成环。 */
    @Query(value = """
            WITH RECURSIVE subtree AS (
                SELECT id FROM mould_categories WHERE id = :rootId
                UNION ALL
                SELECT c.id FROM mould_categories c JOIN subtree s ON c.parent_id = s.id
            )
            SELECT EXISTS(SELECT 1 FROM subtree WHERE id = :candidate)
            """, nativeQuery = true)
    boolean isDescendant(@Param("rootId") UUID rootId, @Param("candidate") UUID candidate);

    /** 按当前 parent_id 原子重建移动子树的 level/path，不依赖移动前的旧 path 排序。 */
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
                FROM mould_categories c
                LEFT JOIN mould_categories parent ON c.parent_id = parent.id
                WHERE c.id = :rootId AND c.is_deleted = false
                UNION ALL
                SELECT child.id,
                       parent.new_level + 1,
                       (parent.new_path || child.code || '/')::text,
                       parent.visited || child.id
                FROM mould_categories child
                JOIN rebuilt parent ON child.parent_id = parent.id
                WHERE NOT child.id = ANY(parent.visited)
            )
            UPDATE mould_categories c
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
}
