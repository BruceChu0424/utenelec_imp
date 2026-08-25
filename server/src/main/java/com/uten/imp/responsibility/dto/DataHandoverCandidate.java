package com.uten.imp.responsibility.dto;

import java.util.UUID;

/** Minimal employee identity exposed only for handover/offboarding pickers. */
public record DataHandoverCandidate(
        UUID employeeId,
        String code,
        String name,
        UUID departmentId,
        String departmentName,
        String status
) {
}
