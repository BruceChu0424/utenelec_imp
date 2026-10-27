package com.uten.imp.features.master.client.dto;

import com.fasterxml.jackson.annotation.JsonCreator;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonPropertyOrder;
import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;
import jakarta.validation.constraints.Size;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** Atomic owner/viewer replacement guarded by the customer's access version. */
@JsonPropertyOrder({"ownerEmployeeId", "viewerEmployeeIds", "expectedAccessVersion", "reason", "ownerEmployeeIds"})
public final class ClientAccessUpdateRequest {
    private final UUID ownerEmployeeId;
    @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS)
    private final List<@NotNull UUID> viewerEmployeeIds;
    @NotNull @PositiveOrZero
    private final Long expectedAccessVersion;
    @NotBlank @Size(max = 1000)
    private final String reason;
    @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS)
    private final List<@NotNull UUID> ownerEmployeeIds;

    @JsonCreator
    public ClientAccessUpdateRequest(
            @JsonProperty("ownerEmployeeId") UUID ownerEmployeeId,
            @JsonProperty("viewerEmployeeIds") @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS) List<@NotNull UUID> viewerEmployeeIds,
            @JsonProperty("expectedAccessVersion") @NotNull @PositiveOrZero Long expectedAccessVersion,
            @JsonProperty("reason") @NotBlank @Size(max = 1000) String reason,
            @JsonProperty("ownerEmployeeIds") @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS) List<@NotNull UUID> ownerEmployeeIds) {
        this.ownerEmployeeId = ownerEmployeeId;
        this.viewerEmployeeIds = viewerEmployeeIds == null ? null
                : Collections.unmodifiableList(new ArrayList<>(viewerEmployeeIds));
        this.expectedAccessVersion = expectedAccessVersion;
        this.reason = reason;
        this.ownerEmployeeIds = ownerEmployeeIds == null ? null
                : Collections.unmodifiableList(new ArrayList<>(ownerEmployeeIds));
    }

    public ClientAccessUpdateRequest(UUID ownerEmployeeId, List<UUID> viewerEmployeeIds,
            Long expectedAccessVersion, String reason) {
        this(ownerEmployeeId, viewerEmployeeIds, expectedAccessVersion, reason, null);
    }

    @JsonProperty("ownerEmployeeId")
    public UUID ownerEmployeeId() {
        return ownerEmployeeId;
    }

    @JsonProperty("viewerEmployeeIds")
    @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS)
    public List<@NotNull UUID> viewerEmployeeIds() {
        return viewerEmployeeIds == null ? null : Collections.unmodifiableList(viewerEmployeeIds);
    }

    @JsonProperty("expectedAccessVersion")
    @NotNull @PositiveOrZero
    public Long expectedAccessVersion() {
        return expectedAccessVersion;
    }

    @JsonProperty("reason")
    @NotBlank @Size(max = 1000)
    public String reason() {
        return reason;
    }

    @JsonProperty("ownerEmployeeIds")
    @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS)
    public List<@NotNull UUID> ownerEmployeeIds() {
        return ownerEmployeeIds == null ? null : Collections.unmodifiableList(ownerEmployeeIds);
    }

    @Override
    public boolean equals(Object other) {
        return this == other || other instanceof ClientAccessUpdateRequest that
                && Objects.equals(ownerEmployeeId, that.ownerEmployeeId)
                && Objects.equals(viewerEmployeeIds, that.viewerEmployeeIds)
                && Objects.equals(expectedAccessVersion, that.expectedAccessVersion)
                && Objects.equals(reason, that.reason)
                && Objects.equals(ownerEmployeeIds, that.ownerEmployeeIds);
    }

    @Override
    public int hashCode() {
        int hash = Objects.hashCode(ownerEmployeeId);
        hash = 31 * hash + Objects.hashCode(viewerEmployeeIds);
        hash = 31 * hash + Objects.hashCode(expectedAccessVersion);
        hash = 31 * hash + Objects.hashCode(reason);
        return 31 * hash + Objects.hashCode(ownerEmployeeIds);
    }

    @Override
    public String toString() {
        return "ClientAccessUpdateRequest[ownerEmployeeId=" + ownerEmployeeId
                + ", viewerEmployeeIds=" + viewerEmployeeIds
                + ", expectedAccessVersion=" + expectedAccessVersion
                + ", reason=" + reason
                + ", ownerEmployeeIds=" + ownerEmployeeIds + "]";
    }
}
