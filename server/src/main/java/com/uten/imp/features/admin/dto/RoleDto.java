package com.uten.imp.features.admin.dto;

import com.uten.imp.features.rbac.Role;

import java.util.List;
import java.util.UUID;

public record RoleDto(UUID id, String code, String name, String description, List<String> permissions) {
    public static RoleDto of(Role r, List<String> permissions) {
        return new RoleDto(r.getId(), r.getCode(), r.getName(), r.getDescription(), permissions);
    }
}
