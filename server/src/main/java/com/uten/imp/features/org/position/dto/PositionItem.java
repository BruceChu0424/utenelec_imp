package com.uten.imp.features.org.position.dto;

import java.util.UUID;

/** 岗位列表项 / 详情响应。 */
public record PositionItem(
        UUID id,
        String code,
        String name,
        String level,
        Integer sortOrder
) {
}
