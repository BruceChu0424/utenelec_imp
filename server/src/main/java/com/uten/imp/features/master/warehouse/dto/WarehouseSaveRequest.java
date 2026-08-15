package com.uten.imp.features.master.warehouse.dto;

import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonSetter;
import jakarta.validation.constraints.NotBlank;
import lombok.Getter;
import lombok.Setter;

import java.util.UUID;

/**
 * 仓库新建/编辑请求（warehouse:edit）。
 *
 * <p>名称（必填）/ 编号 / 位置 / 备注 / 是否核算 / 所属车间 UUID / 状态。
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
    private UUID workshopDepartmentId;
    @JsonIgnore
    private boolean workshopDepartmentReferenceSpecified;
    private String status;           // 使用/禁用

    @JsonSetter("workshopDepartmentId")
    public void setWorkshopDepartmentId(UUID workshopDepartmentId) {
        this.workshopDepartmentId = workshopDepartmentId;
        this.workshopDepartmentReferenceSpecified = true;
    }

    /** Omitted on update means preserve; explicit JSON null means clear. */
    public boolean hasWorkshopDepartmentReference() {
        return workshopDepartmentReferenceSpecified;
    }
}
