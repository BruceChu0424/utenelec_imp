package com.uten.imp.features.admin.dto;

import java.util.UUID;

/**
 * 开通账号候选员工（GET /api/admin/users/provision-candidates）。
 *
 * <p>最小信息集：仅姓名/工号/部门 + 「是否已登记手机号/身份证」布尔位
 * （不开解密、不回传任何 PII 明文），供权限设置页选择要开通账号的员工。
 * 缺少手机号或身份证时后端开通会失败，前端据此提前置灰并提示原因。
 */
public record ProvisionCandidateDto(
        UUID employeeId,
        String name,
        String code,
        String departmentName,
        boolean hasPhone,
        boolean hasIdCard) {}
