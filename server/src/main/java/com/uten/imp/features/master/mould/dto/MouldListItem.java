package com.uten.imp.features.master.mould.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 模具列表项。
 *
 * <p>仅承载表格中"有数据"的列（编号/名称/存放位置/制造日期/备注/状态）+ legacyId。
 * 表格里另有 4 列（模数/套数/模具类型/制造商）在 V34 表无对应字段，由前端以 null 取值
 * 显示"—"，不参与后端筛选/facet，故不在此 DTO 内。
 *
 * <p>字段均为小写命名，无 Jackson 连续大写陷阱（参考 goods 的 mWeight/cNumber）。
 */
@Getter
@AllArgsConstructor
public class MouldListItem {
    private UUID id;
    private String code;        // 模具编号（Number）
    private String name;        // 模具名称（MouldName）
    private String place;       // 存放位置（车间/位置）
    private String mstatus;     // 制造日期（源 MStatus，制造年月如 2018年7月）
    private String status;      // 状态（生命周期：使用/禁用）
    private String remark;      // 备注
    private Integer legacyId;
}
