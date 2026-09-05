package com.uten.imp.application.port;

import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;

/**
 * Read-only subcontract document capability exposed to cross-feature query
 * projections. Implementations retain authority and owner-scope policy inside
 * the subcontract feature; callers receive only a bindable SQL scope.
 */
public interface SubcontractDocumentReadAccessPort {

    boolean hasAuthority(String authority);

    NativeReadScope nativeReadScope(
            String ownerColumn,
            String parameterName,
            String... operationAuthorities);
}
