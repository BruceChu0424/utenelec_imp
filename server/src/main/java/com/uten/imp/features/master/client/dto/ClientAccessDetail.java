package com.uten.imp.features.master.client.dto;

import java.util.List;
import java.util.UUID;

/** Authoritative owner and explicit viewer configuration for one customer. */
public record ClientAccessDetail(
        UUID clientId,
        UUID ownerEmployeeId,
        String ownerEmployeeName,
        long accessVersion,
        List<ClientAccessViewer> viewers) {
}
