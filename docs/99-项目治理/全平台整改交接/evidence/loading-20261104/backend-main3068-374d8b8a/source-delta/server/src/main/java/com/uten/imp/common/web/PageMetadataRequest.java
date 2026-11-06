package com.uten.imp.common.web;

import jakarta.servlet.http.HttpServletRequest;

/** Optional continuation-page optimization; absence preserves the original complete response. */
public final class PageMetadataRequest {
    private PageMetadataRequest() { }
    public static boolean included(HttpServletRequest request) {
        String raw=request==null?null:request.getParameter("includeMetadata");
        if(raw==null)return true;
        return switch(raw.strip().toLowerCase(java.util.Locale.ROOT)) {
            case "true" -> true;
            case "false" -> false;
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED,"includeMetadata须为true或false");
        };
    }
}
