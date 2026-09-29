package com.uten.imp.features.stock.weight.dto;

import jakarta.validation.constraints.Size;

/**
 * 排除一条称重记录 (POST /api/stock/weight/observations/{observationId}/exclude)。
 *
 * @param reason 排除原因 (可空; 填写时 2-200 字, 记进该记录备注)
 */
public record WeightExcludeRequest(@Size(max = 200) String reason) {
}
