package com.uten.imp.features.master.warehouse.dto;

import jakarta.validation.constraints.NotBlank;
import lombok.Getter;
import lombok.Setter;

/**
 * 仓库新建/编辑请求（warehouse:edit）。
 *
 * <p>名称（必填）/ 编号 / 位置 / 备注 / 是否核算 / 所属车间 legacy / 状态。
 * legacy_id/审计/软删/auto_created 不可改；新建与编辑共用本 DTO。
 */
@Getter
@Setter
public class WarehouseSaveRequest {

    @NotBlank
    private String name;             // 仓库名称
    private String code;             // 仓库编号
    private String location;         // 仓库位置
    private String remark;           // 备注
    private Boolean accountable;     // 是否参与库存核算（null 时保留默认 true）
    private Integer workshopLegacyId;// 所属车间 legacy id
    private String status;           // 使用/禁用
}
