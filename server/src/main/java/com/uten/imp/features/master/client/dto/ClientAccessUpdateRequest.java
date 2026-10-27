package com.uten.imp.features.master.client.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/** Atomic owner/viewer replacement guarded by the customer's access version. */
public record ClientAccessUpdateRequest(
        UUID ownerEmployeeId,
        @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS) List<@NotNull UUID> viewerEmployeeIds,
        @NotNull @PositiveOrZero Long expectedAccessVersion,
        @NotBlank @Size(max = 1000) String reason,
        @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS) List<@NotNull UUID> ownerEmployeeIds) {
    public ClientAccessUpdateRequest(UUID ownerEmployeeId, List<UUID> viewerEmployeeIds,
            Long expectedAccessVersion, String reason) {
        this(ownerEmployeeId, viewerEmployeeIds, expectedAccessVersion, reason, null);
    }
}
