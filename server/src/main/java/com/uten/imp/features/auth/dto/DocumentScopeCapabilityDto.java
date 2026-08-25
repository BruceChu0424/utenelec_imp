package com.uten.imp.features.auth.dto;

import java.util.List;
import java.util.UUID;

/**
 * 当前登录主体在一个单据数据范围内的普通写能力。
 *
 * <p>{@code writeAll} 只来自超级管理员或显式 {@code *:view:all} 高权；
 * {@code writableOwnerIds} 只包含本人和正式交接继承的历史归属人。手工
 * {@code user_data_scopes} 仅扩展可见范围，绝不会出现在本响应的可写集合中。
 */
public record DocumentScopeCapabilityDto(
        String scope,
        boolean writeAll,
        List<UUID> writableOwnerIds) {
}
