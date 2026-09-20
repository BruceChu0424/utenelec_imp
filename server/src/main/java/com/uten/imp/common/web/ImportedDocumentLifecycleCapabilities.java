package com.uten.imp.common.web;

import com.fasterxml.jackson.annotation.JsonProperty;

/** Imported original documents remain visible evidence and cannot restart their business lifecycle. */
public interface ImportedDocumentLifecycleCapabilities extends StandardDocumentLifecycleCapabilities {
    String READ_ONLY_REASON="历史原始单据仅供核对，不能编辑、删除、再次审核入库或红冲";
    Integer getLegacyId();

    static void requireMutable(Integer legacyId) {
        if(legacyId!=null)throw new ApiException(ErrorCode.BUSINESS,READ_ONLY_REASON);
    }

    @JsonProperty("legacyImported")
    default boolean isLegacyImported(){return getLegacyId()!=null;}
    @Override default boolean isCanEdit(){return !isLegacyImported()&&StandardDocumentLifecycleCapabilities.super.isCanEdit();}
    @Override default boolean isCanDelete(){return !isLegacyImported()&&StandardDocumentLifecycleCapabilities.super.isCanDelete();}
    @Override default boolean isCanReverse(){return !isLegacyImported()&&StandardDocumentLifecycleCapabilities.super.isCanReverse();}
    @JsonProperty("canApprove")
    default boolean isCanApprove(){return !isLegacyImported()&&StandardDocumentLifecycleCapabilities.isDraft(getStatus());}
    @JsonProperty("restrictionReason")
    default String getRestrictionReason(){return isLegacyImported()?READ_ONLY_REASON:null;}
}
