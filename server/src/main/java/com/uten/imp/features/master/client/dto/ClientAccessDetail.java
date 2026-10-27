package com.uten.imp.features.master.client.dto;

import com.fasterxml.jackson.annotation.JsonCreator;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonPropertyOrder;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** Authoritative owner and explicit viewer configuration for one customer. */
@JsonPropertyOrder({"clientId", "ownerEmployeeId", "ownerEmployeeName", "accessVersion", "viewers", "owners"})
public final class ClientAccessDetail {
    private final UUID clientId;
    private final UUID ownerEmployeeId;
    private final String ownerEmployeeName;
    private final long accessVersion;
    private final List<ClientAccessViewer> viewers;
    private final List<ClientAccessViewer> owners;

    @JsonCreator
    public ClientAccessDetail(
            @JsonProperty("clientId") UUID clientId,
            @JsonProperty("ownerEmployeeId") UUID ownerEmployeeId,
            @JsonProperty("ownerEmployeeName") String ownerEmployeeName,
            @JsonProperty("accessVersion") long accessVersion,
            @JsonProperty("viewers") List<ClientAccessViewer> viewers,
            @JsonProperty("owners") List<ClientAccessViewer> owners) {
        this.clientId = clientId;
        this.ownerEmployeeId = ownerEmployeeId;
        this.ownerEmployeeName = ownerEmployeeName;
        this.accessVersion = accessVersion;
        this.viewers = viewers == null ? null
                : Collections.unmodifiableList(new ArrayList<>(viewers));
        this.owners = owners == null ? null
                : Collections.unmodifiableList(new ArrayList<>(owners));
    }

    public ClientAccessDetail(UUID clientId, UUID ownerEmployeeId, String ownerEmployeeName,
            long accessVersion, List<ClientAccessViewer> viewers) {
        this(clientId, ownerEmployeeId, ownerEmployeeName, accessVersion, viewers, List.of());
    }

    @JsonProperty("clientId")
    public UUID clientId() {
        return clientId;
    }

    @JsonProperty("ownerEmployeeId")
    public UUID ownerEmployeeId() {
        return ownerEmployeeId;
    }

    @JsonProperty("ownerEmployeeName")
    public String ownerEmployeeName() {
        return ownerEmployeeName;
    }

    @JsonProperty("accessVersion")
    public long accessVersion() {
        return accessVersion;
    }

    @JsonProperty("viewers")
    public List<ClientAccessViewer> viewers() {
        return viewers == null ? null : Collections.unmodifiableList(viewers);
    }

    @JsonProperty("owners")
    public List<ClientAccessViewer> owners() {
        return owners == null ? null : Collections.unmodifiableList(owners);
    }

    @Override
    public boolean equals(Object other) {
        return this == other || other instanceof ClientAccessDetail that
                && Objects.equals(clientId, that.clientId)
                && Objects.equals(ownerEmployeeId, that.ownerEmployeeId)
                && Objects.equals(ownerEmployeeName, that.ownerEmployeeName)
                && accessVersion == that.accessVersion
                && Objects.equals(viewers, that.viewers)
                && Objects.equals(owners, that.owners);
    }

    @Override
    public int hashCode() {
        int hash = Objects.hashCode(clientId);
        hash = 31 * hash + Objects.hashCode(ownerEmployeeId);
        hash = 31 * hash + Objects.hashCode(ownerEmployeeName);
        hash = 31 * hash + Long.hashCode(accessVersion);
        hash = 31 * hash + Objects.hashCode(viewers);
        return 31 * hash + Objects.hashCode(owners);
    }

    @Override
    public String toString() {
        return "ClientAccessDetail[clientId=" + clientId
                + ", ownerEmployeeId=" + ownerEmployeeId
                + ", ownerEmployeeName=" + ownerEmployeeName
                + ", accessVersion=" + accessVersion
                + ", viewers=" + viewers
                + ", owners=" + owners + "]";
    }
}
