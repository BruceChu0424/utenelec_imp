package com.uten.imp.common.web;

import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * Standard 0=draft, 1=approved, -1=reversed detail capabilities.
 *
 * <p>Owner write scope is intentionally separate. These properties only
 * describe server-authoritative lifecycle eligibility for document families
 * without additional workflow locks.
 */
public interface StandardDocumentLifecycleCapabilities {

    Short getStatus();

    static boolean isDraft(Short status) {
        return status != null && status == 0;
    }

    static boolean isApproved(Short status) {
        return status != null && status == 1;
    }

    static void requireDraftForDelete(Short status) {
        if (!isDraft(status)) {
            throw new ApiException(
                    ErrorCode.BUSINESS,
                    "仅草稿单据可删除；已审核请先红冲，红冲历史必须保留");
        }
    }

    @JsonProperty("canEdit")
    default boolean isCanEdit() {
        return isDraft(getStatus());
    }

    @JsonProperty("canDelete")
    default boolean isCanDelete() {
        return isDraft(getStatus());
    }

    @JsonProperty("canReverse")
    default boolean isCanReverse() {
        return isApproved(getStatus());
    }
}
