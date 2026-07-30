package com.uten.imp.features.org.position.dto;

import jakarta.validation.constraints.NotBlank;

/** 更新岗位请求（code 不可改）。 */
public record PositionUpdateRequest(
        @NotBlank String name,
        String level,
        Integer sortOrder
) {
}
