package com.uten.imp.features.master.client.dto;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.fasterxml.jackson.databind.ser.std.ToStringSerializer;

import java.time.OffsetDateTime;
import java.util.UUID;

/** 客户收货地址簿行（出货开单地址弹窗 / 自动带出候选）。 */
public record ClientShipAddressDto(
        @JsonSerialize(using = ToStringSerializer.class) UUID id,
        @JsonSerialize(using = ToStringSerializer.class) UUID clientId,
        String address,
        String linkPhone,
        int usageCount,
        OffsetDateTime lastUsedAt) {
}
