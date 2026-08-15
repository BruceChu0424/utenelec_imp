package com.uten.imp.application.port;

import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/**
 * Read-only organization boundary for business features that persist employee or department UUIDs.
 *
 * <p>The owning {@code org} feature implements this port. Consumers only receive immutable identity
 * projections, so organization JPA entities and repositories never leak across feature boundaries.
 */
public interface OrganizationReferencePort {

    Optional<EmployeeReference> findActiveEmployee(UUID employeeId);

    Optional<DepartmentReference> findActiveDepartment(UUID departmentId);

    Optional<DepartmentReference> findActiveDepartmentByCode(String code);

    List<DepartmentReference> findActiveChildrenOfDepartmentCode(String parentCode);

    Map<UUID, String> findActiveDepartmentNames(Collection<UUID> departmentIds);

    record EmployeeReference(UUID id, Integer legacyId, UUID departmentId) {}

    record DepartmentReference(
            UUID id,
            String code,
            String name,
            UUID parentId,
            String parentCode) {}
}
