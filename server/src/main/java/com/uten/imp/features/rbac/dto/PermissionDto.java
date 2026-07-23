package com.uten.imp.features.rbac.dto;

import com.uten.imp.features.rbac.Permission;

import java.util.UUID;

public record PermissionDto(UUID id, String code, String name, String category) {
    public static PermissionDto of(Permission p) {
        return new PermissionDto(p.getId(), p.getCode(), p.getName(), p.getCategory());
    }
}
