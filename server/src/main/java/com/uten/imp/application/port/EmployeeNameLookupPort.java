package com.uten.imp.application.port;

import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/** Read-only employee display-name boundary for cross-feature projections. */
public interface EmployeeNameLookupPort {

    Map<UUID, String> findNames(Set<UUID> employeeIds);

    Optional<String> findName(UUID employeeId);
}
