package com.uten.imp.features.master.client.dto;

import com.fasterxml.jackson.annotation.JsonCreator;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonPropertyOrder;
import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Objects;
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
@JsonPropertyOrder({"clientIds", "ownerEmployeeId", "viewerEmployeeIds", "reason", "ownerEmployeeIds"})
public final class ClientAccessBatchUpdateRequest {
    @NotEmpty @Size(max = RequestLimits.BATCH_IDS)
    private final List<@NotNull UUID> clientIds;
    private final UUID ownerEmployeeId;
    @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS)
    private final List<@NotNull UUID> viewerEmployeeIds;
    @NotBlank @Size(max = 1000)
    private final String reason;
    @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS)
    private final List<@NotNull UUID> ownerEmployeeIds;

    @JsonCreator
    public ClientAccessBatchUpdateRequest(
            @JsonProperty("clientIds") @NotEmpty @Size(max = RequestLimits.BATCH_IDS) List<@NotNull UUID> clientIds,
            @JsonProperty("ownerEmployeeId") UUID ownerEmployeeId,
            @JsonProperty("viewerEmployeeIds") @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS) List<@NotNull UUID> viewerEmployeeIds,
            @JsonProperty("reason") @NotBlank @Size(max = 1000) String reason,
            @JsonProperty("ownerEmployeeIds") @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS) List<@NotNull UUID> ownerEmployeeIds) {
        this.clientIds = clientIds == null ? null
                : Collections.unmodifiableList(new ArrayList<>(clientIds));
        this.ownerEmployeeId = ownerEmployeeId;
        this.viewerEmployeeIds = viewerEmployeeIds == null ? null
                : Collections.unmodifiableList(new ArrayList<>(viewerEmployeeIds));
        this.reason = reason;
        this.ownerEmployeeIds = ownerEmployeeIds == null ? null
                : Collections.unmodifiableList(new ArrayList<>(ownerEmployeeIds));
    }

    public ClientAccessBatchUpdateRequest(List<UUID> clientIds, UUID ownerEmployeeId,
            List<UUID> viewerEmployeeIds, String reason) {
        this(clientIds, ownerEmployeeId, viewerEmployeeIds, reason, null);
    }

    @JsonProperty("clientIds")
    @NotEmpty @Size(max = RequestLimits.BATCH_IDS)
    public List<@NotNull UUID> clientIds() {
        return clientIds == null ? null : Collections.unmodifiableList(clientIds);
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
        return this == other || other instanceof ClientAccessBatchUpdateRequest that
                && Objects.equals(clientIds, that.clientIds)
                && Objects.equals(ownerEmployeeId, that.ownerEmployeeId)
                && Objects.equals(viewerEmployeeIds, that.viewerEmployeeIds)
                && Objects.equals(reason, that.reason)
                && Objects.equals(ownerEmployeeIds, that.ownerEmployeeIds);
    }

    @Override
    public int hashCode() {
        int hash = Objects.hashCode(clientIds);
        hash = 31 * hash + Objects.hashCode(ownerEmployeeId);
        hash = 31 * hash + Objects.hashCode(viewerEmployeeIds);
        hash = 31 * hash + Objects.hashCode(reason);
        return 31 * hash + Objects.hashCode(ownerEmployeeIds);
    }

    @Override
    public String toString() {
        return "ClientAccessBatchUpdateRequest[clientIds=" + clientIds
                + ", ownerEmployeeId=" + ownerEmployeeId
                + ", viewerEmployeeIds=" + viewerEmployeeIds
                + ", reason=" + reason
                + ", ownerEmployeeIds=" + ownerEmployeeIds + "]";
    }
}
