package com.uten.imp.support;

import com.uten.imp.features.production.dailyreport.dto.DailyReportApproveRequest;

import java.util.UUID;

/**
 * 端到端用例统一取一把新幂等键。
 *
 * <p>每次调用都代表「一次新点击」；同键重发的回放语义由
 * ProductionDailyReportCommandTest 与命令账本的 PostgreSQL 用例专门覆盖，
 * 不在链路用例里顺带验证，免得两边都说不清楚。
 */
public final class DailyReportApproveRequests {

    private DailyReportApproveRequests() {
    }

    public static DailyReportApproveRequest freshKey() {
        DailyReportApproveRequest request = new DailyReportApproveRequest();
        request.setIdempotencyKey("e2e-approve-" + UUID.randomUUID());
        return request;
    }
}
