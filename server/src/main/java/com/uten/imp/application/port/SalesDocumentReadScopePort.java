package com.uten.imp.application.port;

import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;

/** Shared readers use the authoritative sales owner scope without importing sales internals. */
public interface SalesDocumentReadScopePort {
    NativeReadScope nativeReadScope(String ownerColumn, String parameterName);
}
