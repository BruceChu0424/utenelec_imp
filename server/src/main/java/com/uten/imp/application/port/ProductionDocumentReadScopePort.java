package com.uten.imp.application.port;

import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;

/** Production keeps its maker, handover and operation-specific read rules authoritative. */
public interface ProductionDocumentReadScopePort {
    default com.uten.imp.security.OwnerVisibility.OwnerScope scope(String... operationAuthorities) {
        throw new UnsupportedOperationException("Production owner authority is required");
    }
    boolean hasAuthority(String authority);
    NativeReadScope nativeReadScope(String ownerColumn,String parameterName,String... operationAuthorities);
}
