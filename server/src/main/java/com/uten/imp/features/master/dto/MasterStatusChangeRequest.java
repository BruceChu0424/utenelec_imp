package com.uten.imp.features.master.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;

/**
 * Narrow status-only master-data command.
 *
 * <p>The optional version is required by versioned masters and ignored by
 * legacy masters that are serialized with a pessimistic row lock. Keeping
 * status on a dedicated command prevents a stale full edit form from
 * overwriting unrelated fields when a user only enables or disables a row.
 */
public record MasterStatusChangeRequest(
        @NotBlank @Pattern(regexp = "使用|禁用") String status,
        Long version) {
    /** Also enforce the command contract for trusted in-process callers. */
    public void requireValidStatus() {
        com.uten.imp.common.domain.MasterStatuses.requireValid(status);
    }
}
