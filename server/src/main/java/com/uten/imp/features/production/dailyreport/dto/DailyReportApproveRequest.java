package com.uten.imp.features.production.dailyreport.dto;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

/**
 * 审核生产日报请求。
 *
 * <p>审核是整条报工链里最重的一次写，客户端必须带幂等键：连接被掐断时事务往往已经提交，
 * 同键重发要原样回放已审详情，而不是撞上状态闸门再让人分不清「刚才其实成功了」。
 */
@Getter
@Setter
public class DailyReportApproveRequest {
    @NotNull
    @Size(min = 8, max = 128)
    private String idempotencyKey;
}
