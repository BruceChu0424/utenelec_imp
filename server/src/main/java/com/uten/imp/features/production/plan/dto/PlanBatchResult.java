package com.uten.imp.features.production.plan.dto;

import java.util.List;
import java.util.UUID;

/**
 * 生产计划批量动作结果：done 是本次已处理的计划；skipped 是提交前就不满足条件、
 * 本次没有动的计划(带原因)。任何一张在处理中失败，整批回滚并报错，不会出现只成一半。
 */
public record PlanBatchResult(List<Done> done, List<Skipped> skipped) {

    public record Done(UUID id, String billNo) {
    }

    public record Skipped(UUID id, String billNo, String reason) {
    }
}
