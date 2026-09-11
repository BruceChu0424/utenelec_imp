package com.uten.imp.features.master.client.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/**
 * Batch owner/viewer maintenance for a multi-selected customer list.
 *
 * <p>Unlike the single-customer request there is no caller-supplied access
 * version: the operator selected rows in a list, not a specific revision, so
 * each customer's current version is read under its own write lock inside the
 * same transaction. A null field means "leave that dimension untouched" —
 * assigning an owner to fifty customers must not silently wipe their
 * individually curated viewer lists.
 */
public record ClientAccessBatchUpdateRequest(
        @NotEmpty @Size(max = RequestLimits.BATCH_IDS) List<@NotNull UUID> clientIds,
        UUID ownerEmployeeId,
        @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS) List<@NotNull UUID> viewerEmployeeIds,
        @NotBlank @Size(max = 1000) String reason) {
}
