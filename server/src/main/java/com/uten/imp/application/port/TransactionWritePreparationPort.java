package com.uten.imp.application.port;

/**
 * Prepares request-specific write coordination after transaction provenance is
 * bound and before the first business statement. Implementations must keep
 * unrelated requests cheap and must not perform business mutations here.
 */
public interface TransactionWritePreparationPort {
    void prepare(String requestPath, String requestMethod);
}
