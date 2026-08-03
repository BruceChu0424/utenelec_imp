package com.uten.imp.features.org.position;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface PositionRepository extends JpaRepository<Position, UUID> {

    List<Position> findByDepartmentIdAndDeletedFalseOrderBySortOrderAscIdAsc(UUID departmentId);

    /** 编码唯一约束 (code, department_id) 含软删行，查重时不过滤 deleted。 */
    boolean existsByCodeAndDepartmentId(String code, UUID departmentId);

    Optional<Position> findByIdAndDepartmentIdAndDeletedFalse(UUID id, UUID departmentId);

    /**
     * 按规范化名称复用本部门第一条活动岗位。历史迁移可能留下同名行，因此必须显式排序并 LIMIT 1，
     * 不能用期望唯一结果的派生 Optional 查询。
     */
    @Query(value = """
            SELECT p.*
            FROM positions p
            WHERE p.department_id = :departmentId
              AND p.is_deleted = false
              AND lower(btrim(p.name)) = :normalizedName
            ORDER BY p.sort_order ASC, p.id ASC
            LIMIT 1
            """, nativeQuery = true)
    Optional<Position> findFirstActiveByNormalizedName(
            @Param("departmentId") UUID departmentId,
            @Param("normalizedName") String normalizedName);
}
