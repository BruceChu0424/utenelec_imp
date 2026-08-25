package com.uten.imp.features.master.client.dto;

import java.util.UUID;

/** One current employee with explicit read-only access to a customer. */
public record ClientAccessViewer(
        UUID employeeId,
        String name,
        String code,
        String departmentName) {
}
