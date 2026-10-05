package com.uten.imp.features.admin.dto;

import java.util.UUID;

/**
 * 开通账号候选员工（GET /api/admin/users/provision-candidates）。
 *
 * <p>最小信息集：仅姓名/工号/部门 + 「是否已登记手机号」布尔位
 * （不开解密、不回传任何 PII 明文），供权限设置页选择要开通账号的员工。
 * 只有缺少手机号会让开通失败，前端据此提前置灰并提示原因；证件号码有问题不影响开通，
 * 在开号确认时提醒 (V807)。
 */
public record ProvisionCandidateDto(
        UUID employeeId,
        String name,
        String code,
        String departmentName,
        boolean hasPhone) {}
