package com.uten.imp.application.port;

import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;

/** Production keeps its maker, handover and operation-specific read rules authoritative. */
public interface ProductionDocumentReadScopePort {
    boolean hasAuthority(String authority);
    NativeReadScope nativeReadScope(String ownerColumn,String parameterName,String... operationAuthorities);
}
