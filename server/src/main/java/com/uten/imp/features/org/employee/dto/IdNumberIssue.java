package com.uten.imp.features.org.employee.dto;

/**
 * 员工档案证件号码需要人事核对的原因 (数据质量提示，不是 PII)。
 *
 * <p>只由 {@code EmployeeIdentityCheck.issueOf} 构造；为 null 表示无需处理。
 *
 * @param kind   missing (档案没有证件号码) / invalid (身份证号没通过校验) /
 *               unchecked (历史导入、系统还没校验完，或档案里的号码读取不出来、没法校验)
 * @param reason 服务端拼好的中文原因，例如「身份证号应为18位，当前为17位」；
 *               只含位置和长度，绝不含号码或其中任何一段
 */
public record IdNumberIssue(String kind, String reason) {
}
