package com.uten.imp.features.org.department;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface DepartmentRepository extends JpaRepository<Department, UUID> {

    boolean existsByCode(String code);

    List<Department> findByParentIdOrderBySortOrderAscNameAsc(UUID parentId);

    List<Department> findByManagerId(UUID managerId);

    List<Department> findByDeletedFalseOrderBySortOrderAscNameAsc();

    /** 递归 CTE：返回某部门及其全部后代（含自身），仅未软删。 */
    @Query(value = """
            WITH RECURSIVE subtree AS (
                SELECT id FROM departments WHERE id = :rootId AND is_deleted = false
                UNION ALL
                SELECT d.id FROM departments d
                JOIN subtree s ON d.parent_id = s.id
                WHERE d.is_deleted = false
            )
            SELECT d.* FROM departments d
            WHERE d.id IN (SELECT id FROM subtree)
            ORDER BY d.path
            """, nativeQuery = true)
    List<Department> findSubtree(@Param("rootId") UUID rootId);

    /** 判断 candidate 是否为 root 的（含自身）后代——用于部门防成环校验。 */
    @Query(value = """
            WITH RECURSIVE subtree AS (
                SELECT id FROM departments WHERE id = :rootId
                UNION ALL
                SELECT d.id FROM departments d JOIN subtree s ON d.parent_id = s.id
            )
            SELECT EXISTS(SELECT 1 FROM subtree WHERE id = :candidate)
            """, nativeQuery = true)
    boolean isDescendant(@Param("rootId") UUID rootId, @Param("candidate") UUID candidate);
}
