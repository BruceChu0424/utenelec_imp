package com.uten.imp.audit;

/**
 * Runtime policy values consumed by the audit foundation.
 *
 * <p>The implementation lives in the system-settings feature so the foundation
 * package does not depend backwards on a business feature. 审计保留期不在这里:
 * 留存由数据库函数 fn_audit_retention_run() 直接读系统设置(ADR-105), 只算一处。
 */
public interface AuditRuntimeSettings {

    int exportMaxRows();
}
