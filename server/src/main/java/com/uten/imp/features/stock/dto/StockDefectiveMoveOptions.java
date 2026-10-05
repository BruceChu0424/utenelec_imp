package com.uten.imp.features.stock.dto;

import java.util.List;

/**
 * 当前用户能办理的不良品专门通道(ADR-146): TO_DEFECTIVE 转不良品仓 / DEFECT_RELEASE 不良复判转回。
 * 服务端按独立权限算好, 前端只认它决定入口显隐, 不在页面里拼权限。
 */
public record StockDefectiveMoveOptions(List<String> kinds) {
}
