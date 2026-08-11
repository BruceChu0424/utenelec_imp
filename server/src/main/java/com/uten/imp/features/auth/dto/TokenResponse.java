package com.uten.imp.features.auth.dto;

import java.util.List;

public record TokenResponse(
        String accessToken,
        String refreshToken,
        long expiresIn,
        boolean mustChangePassword,
        UserProfile user
) {
    public record UserProfile(
            String id,
            String loginAccount,
            /**
             * 员工档案 ID（employees.id）。Phase 6 起前端用此字段直接查 /api/org/employees/{id}
             * 取完整档案做自助编辑。
             */
            String employeeId,
            String name,
            String code,
            /**
             * 部门名。后端 super admin 也照样返一个 dept 名（DB NOT NULL 约束），
             * 但前端会按 isSuperAdmin 隐藏。
             */
            String department,
            /**
             * 岗位名。super admin 该字段为 null（admin 没设置 position）。
             */
            String position,
            boolean mustChangePassword,
            boolean superAdmin,
            List<String> roles,
            List<String> permissions
    ) {}
}
