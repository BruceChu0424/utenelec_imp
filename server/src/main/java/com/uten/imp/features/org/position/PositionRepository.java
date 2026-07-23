package com.uten.imp.features.org.position;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface PositionRepository extends JpaRepository<Position, UUID> {

    List<Position> findByDepartmentIdOrderBySortOrderAsc(UUID departmentId);
}
