package com.uten.imp.features.admin.dto;

import jakarta.validation.constraints.Size;

/**
 * 「全部授权」的范围：module 与 category 都为空 = 整个目录；只给 module = 该模块；
 * 两者都给 = 该子类。服务端按 grant_policy 过滤，BULK_EXCLUDED / INDIVIDUAL_ONLY /
 * SUPERADMIN_ONLY 的码一律不带上。
 */
public record PermissionBulkScopeDto(
        @Size(max = 64) String module,
        @Size(max = 128) String category) {

    public static PermissionBulkScopeDto everything() {
        return new PermissionBulkScopeDto(null, null);
    }
}
