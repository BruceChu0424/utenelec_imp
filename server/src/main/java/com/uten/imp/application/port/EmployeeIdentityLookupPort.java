package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/** Read-only identity projection. This lookup grants no authority and rewrites no historical UUID. */
public interface EmployeeIdentityLookupPort {
    UUID canonicalEmployeeId(UUID employeeId);
    List<UUID> employeeIdentityMembers(UUID employeeId);
}
