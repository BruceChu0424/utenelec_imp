package com.uten.imp.features.master.client.dto;

import java.util.UUID;

/** Minimal non-PII employee row for customer owner/viewer selection. */
public record ClientAccessCandidate(
        UUID employeeId,
        String name,
        String code,
        String departmentName,
        String status,
        boolean activeAccount) {
}
