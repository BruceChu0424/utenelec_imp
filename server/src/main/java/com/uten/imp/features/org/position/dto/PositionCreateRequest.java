package com.uten.imp.features.org.position.dto;

import jakarta.validation.constraints.NotBlank;

/** 创建岗位请求（挂在指定部门下）。 */
public record PositionCreateRequest(
        @NotBlank String code,
        @NotBlank String name,
        String level,
        Integer sortOrder
) {
}
