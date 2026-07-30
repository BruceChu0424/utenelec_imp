package com.uten.imp.features.org.position;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface PositionRepository extends JpaRepository<Position, UUID> {

    List<Position> findByDepartmentIdAndDeletedFalseOrderBySortOrderAscIdAsc(UUID departmentId);

    /** 编码唯一约束 (code, department_id) 含软删行，查重时不过滤 deleted。 */
    boolean existsByCodeAndDepartmentId(String code, UUID departmentId);
}
