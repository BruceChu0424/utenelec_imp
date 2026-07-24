package com.uten.imp.features.master.supplier.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 供应商列表项（轻量摘要，列表核心字段）。与 MouldListItem 同构，字段换成供应商相关。
 */
@Getter
@AllArgsConstructor
public class SupplierListItem {
    private UUID id;
    private String code;        // 编号（Number）
    private String name;        // 供应商名称（Vend_Name）
    private String status;      // 生命周期（使用/禁用）
    private String place;       // 地区（Vend_Place）
    private String linkman;     // 联系人（Link_Man）
    private Integer legacyId;
}
