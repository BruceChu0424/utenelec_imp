package com.uten.imp.features.master.party;

import jakarta.validation.constraints.NotBlank;

/** 跟进/行为记录保存请求（V579）。 */
public record PartyActivityRecordSaveRequest(
        @NotBlank String kind,
        @NotBlank String content,
        int scoreDelta) {
}
