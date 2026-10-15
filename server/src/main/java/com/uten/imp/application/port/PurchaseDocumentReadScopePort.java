package com.uten.imp.application.port;

import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;

/** Read-only source-document scope; consumers never replace purchase ownership rules. */
public interface PurchaseDocumentReadScopePort {
    boolean hasAuthority(String authority);
    NativeReadScope nativeReadScope(String ownerColumn,String parameterName,String... operationAuthorities);
}
