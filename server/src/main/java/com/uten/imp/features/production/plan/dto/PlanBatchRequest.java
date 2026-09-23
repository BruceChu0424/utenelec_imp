package com.uten.imp.features.production.plan.dto;

import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/** 生产计划批量审核 / 批量删除请求：一次请求、一个事务(permissions-06)。 */
public record PlanBatchRequest(
        @NotEmpty @Size(max = PlanBatchRequest.MAX_PLANS) List<@NotNull UUID> ids) {

    /**
     * 单次批量上限。每张计划审核都要重算预排与出箱通知，单事务串行执行；
     * 50 张以内能在前端接收超时(45 秒)之前完成，也不会一次锁住过多计划。
     * 前端 productionPlanBatchLimit 与此同值。
     */
    public static final int MAX_PLANS = 50;
}
