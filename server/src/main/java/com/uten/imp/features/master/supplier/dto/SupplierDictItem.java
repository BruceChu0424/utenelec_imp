package com.uten.imp.features.master.supplier.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 供应商字典项（id/编号/名称/状态/默认结算方式）—— 采购单据页按 id 解析供应商名用，轻量。
 *
 * <p>全量约 386 条，前端一次性缓存（GET /api/master/suppliers/dict）。
 * status（使用/禁用）供前端单据下拉过滤禁用供应商（名称解析仍用全量）。
 * defaultSettlementMethodId（V452）供采购/委外订货开单时预填默认结账方式（仅预填，
 * 不替换单据必填校验；null 表示供应商未维护默认）。
 */
@Getter
@AllArgsConstructor
public class SupplierDictItem {
    private UUID id;
    private String code;
    private String name;
    private String status;
    private UUID defaultSettlementMethodId;
}
