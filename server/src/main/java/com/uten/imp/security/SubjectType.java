package com.uten.imp.security;

/** 认证主体类型：员工（含 HR/保安/管理层）或访客。区分 JWT typ claim 与 SecurityContext 主体。 */
public enum SubjectType {
    STAFF,
    VISITOR
}
