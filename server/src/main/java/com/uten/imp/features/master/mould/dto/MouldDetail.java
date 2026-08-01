package com.uten.imp.features.master.mould.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 模具详情：列表核心字段 + 关键业务字段（够看即可）。与 GoodsDetail 同构。
 * category_name 由 @ManyToOne category 的 name 取。
 */
@Getter
@AllArgsConstructor
public class MouldDetail {
    // ===== 列表核心 =====
    private UUID id;
    private String code;
    private String name;
    private String status;
    private String place;
    private String keeper;
    private Integer legacyId;

    // ===== 详情扩展 =====
    private UUID categoryId;
    private String categoryName;
    private String mnumber;     // 备用编号
    private String qty;         // 数量（如 1+1）
    private BigDecimal tqty;    // 总数量
    private String mstatus;     // 制造年月
    private String remark;      // 备注

    // ===== 车间/保管人 id 关联（对齐生产计划单；前端 picker 回显用）=====
    private UUID departmentId;
    private String departmentName;
    private UUID keeperId;
    private String keeperName;
}
