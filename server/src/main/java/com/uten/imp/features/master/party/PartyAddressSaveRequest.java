package com.uten.imp.features.master.party;

import jakarta.validation.constraints.NotBlank;

/** 地址保存请求（V579）。 */
public record PartyAddressSaveRequest(
        String kind,
        @NotBlank String address,
        boolean isDefault,
        String remark) {
}
