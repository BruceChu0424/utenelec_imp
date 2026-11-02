package com.uten.imp.features.production.execution;

import java.util.UUID;

/** Business assignment prefill only; never an organization-management or HR projection. */
public record WorkshopAssignmentDefaultView(UUID departmentId, String departmentName,
        UUID responsibleEmployeeId, String responsibleEmployeeName) { }
