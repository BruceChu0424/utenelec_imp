package com.uten.imp.audit;

/**
 * Runtime policy values consumed by the audit foundation.
 *
 * <p>The implementation lives in the system-settings feature so the foundation
 * package does not depend backwards on a business feature.
 */
public interface AuditRuntimeSettings {

    int exportMaxRows();

    int hotRetentionMonths();

    int archiveRetentionMonths();
}
