package com.uten.imp.features.production.mrp;

import java.util.UUID;

/**
 * Learned workshop default for planning UI prefill.
 *
 * <p>This is a convenience projection only. Confirmed execution segments stay
 * the authority for the workshop that was actually scheduled. 2026-09-06 起
 * 同时带出学习到的负责人（员工在职才返回，否则两个字段为 null）。</p>
 */
public record GoodsWorkshopPreferenceView(
        UUID goodsId,
        UUID departmentId,
        String departmentName,
        UUID responsibleEmployeeId,
        String responsibleEmployeeName) {
}
