package com.uten.imp.features.rbac.dto;

import com.uten.imp.features.rbac.Role;

import java.util.UUID;

public record RoleDto(UUID id, String code, String name, String description) {
    public static RoleDto of(Role r) {
        return new RoleDto(r.getId(), r.getCode(), r.getName(), r.getDescription());
    }
}
