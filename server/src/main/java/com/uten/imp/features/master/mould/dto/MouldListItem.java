package com.uten.imp.features.master.mould.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 模具列表项。
 *
 * <p>承载实际列表字段及所属系列分类（历史模具系列即 mould_categories，未另造 series）。
 * 表格里的「模数/套数」即老库 QTY/TQTY（2026-10-19 用户确认口径：QTY "1+1" 为模数、
 * TQTY 总数量为套数），随列表带出；「模具类型」仍无数据源，由前端以 null 显示"—"。
 *
 * <p>字段均为小写命名，无 Jackson 连续大写陷阱（参考 goods 的 mWeight/cNumber）。
 */
@Getter
@AllArgsConstructor
public class MouldListItem {
    private UUID id;
    private String code;        // 模具编号（Number）
    private String name;        // 模具名称（MouldName）
    private String qty;         // 模数（老库 QTY，字符串如 "1+1"）
    private BigDecimal tqty;    // 套数（老库 TQTY 总数量）
    private String place;       // 存放位置（车间/位置）
    private String mstatus;     // 制造日期（源 MStatus，制造年月如 2018年7月）
    private String status;      // 状态（生命周期：使用/禁用）
    private String remark;      // 备注
    private Integer legacyId;
    private UUID categoryId;    // 所属分类 id（模具资料页"搜模具定位分类"用）
    private String manufacturer;
    private String categoryName; // 真正所属的模具系列/分类名称，仅作显示，关系仍用 categoryId
}
