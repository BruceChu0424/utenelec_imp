package com.uten.imp.features.admin.dto;

/** Plain-language catalog for one owner-based data visibility scope. */
public record DataScopeDefinitionDto(
        String scope,
        String label,
        String description,
        String viewAllPermission,
        boolean enabled,
        String disabledReason,
        String group) {
}
