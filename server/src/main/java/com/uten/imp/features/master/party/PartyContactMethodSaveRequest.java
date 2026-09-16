package com.uten.imp.features.master.party;

import jakarta.validation.constraints.NotBlank;

/** 联系方式保存请求（V579）。 */
public record PartyContactMethodSaveRequest(
        @NotBlank String kind,
        @NotBlank String value,
        boolean isPrimary,
        String remark) {
}
