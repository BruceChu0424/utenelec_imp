package com.uten.imp.features.master.supplier.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 供应商字典项（id/编号/名称）—— 采购单据页按 id 解析供应商名用，轻量。
 *
 * <p>全量约 386 条，前端一次性缓存（GET /api/master/suppliers/dict）。
 */
@Getter
@AllArgsConstructor
public class SupplierDictItem {
    private UUID id;
    private String code;
    private String name;
}
