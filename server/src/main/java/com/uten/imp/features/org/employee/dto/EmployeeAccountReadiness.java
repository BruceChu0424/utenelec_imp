package com.uten.imp.features.org.employee.dto;

/**
 * 开号就绪检查 (GET /api/org/employees/{id}/account/readiness，account:support)。
 *
 * <p>不解密、不含号码：只说明有没有手机号 (没有就开不了号) 和证件号码有没有需要人事核对的问题
 * (有问题照样能开号，只是提醒)。
 *
 * @param hasPhone      档案里是否有手机号 (登录账号就是手机号)
 * @param idNumberIssue 证件号码问题，null 表示没有
 */
public record EmployeeAccountReadiness(boolean hasPhone, IdNumberIssue idNumberIssue) {
}
