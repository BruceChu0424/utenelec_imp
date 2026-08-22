package com.uten.imp.features.master.dto;

import jakarta.validation.constraints.NotBlank;

/**
 * Narrow status-only master-data command.
 *
 * <p>The optional version is required by versioned masters and ignored by
 * legacy masters that are serialized with a pessimistic row lock. Keeping
 * status on a dedicated command prevents a stale full edit form from
 * overwriting unrelated fields when a user only enables or disables a row.
 */
public record MasterStatusChangeRequest(
        @NotBlank String status,
        Long version) {
}
