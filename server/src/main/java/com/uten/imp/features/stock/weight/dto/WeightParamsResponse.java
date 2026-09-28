package com.uten.imp.features.stock.weight.dto;

import java.util.List;

/** POST /api/stock/weight/params 响应体, items 与请求 lines 同序。 */
public record WeightParamsResponse(List<WeightParams> items) {
}
