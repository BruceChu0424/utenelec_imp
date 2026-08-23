package com.uten.imp.features.admin.dto;

import com.uten.imp.features.rbac.Permission;

import java.util.UUID;

public record PermissionDto(
        UUID id,
        String code,
        String name,
        String category,
        String module,
        String actionType,
        String description,
        boolean active,
        boolean assignable) {

    public static PermissionDto of(Permission p) {
        return new PermissionDto(
                p.getId(),
                p.getCode(),
                p.getName(),
                p.getCategory(),
                p.getModule(),
                normalizedActionType(p.getActionType()),
                p.getDescription(),
                p.isActive(),
                p.isAssignable());
    }

    private static String normalizedActionType(String value) {
        return value == null || value.isBlank() ? "OTHER" : value;
    }
}
