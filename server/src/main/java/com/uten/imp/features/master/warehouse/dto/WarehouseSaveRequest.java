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
    /** 线边仓标记（V584）：null=不改；新建默认否。置「是」须同时有所属车间且参与核算。 */
    private Boolean isLineSide;
    private UUID workshopDepartmentId;
    @JsonIgnore
    private boolean workshopDepartmentReferenceSpecified;
    /**
     * 上级仓库(ADR-145): 只能是唯一主仓; 不传或传空 = 服务端补成主仓。主仓自己没有上级。
     */
    private UUID parentId;
    @JsonIgnore
    private boolean parentReferenceSpecified;
    private String status;           // 使用/禁用
    /**
     * 仓库用途(ADR-145): true=不良品仓, false=良品仓; null=不改(新建默认良品仓)。
     * 不良品仓只能是子仓、不能是车间内料仓, 有库存或还是货品所属仓库时不能改用途。
     */
    private Boolean defective;

    @JsonSetter("workshopDepartmentId")
    public void setWorkshopDepartmentId(UUID workshopDepartmentId) {
        this.workshopDepartmentId = workshopDepartmentId;
        this.workshopDepartmentReferenceSpecified = true;
    }

    /** Omitted on update means preserve; explicit JSON null means clear. */
    public boolean hasWorkshopDepartmentReference() {
        return workshopDepartmentReferenceSpecified;
    }

    @JsonSetter("parentId")
    public void setParentId(UUID parentId) {
        this.parentId = parentId;
        this.parentReferenceSpecified = true;
    }

    /** 是否带了上级仓库字段(ADR-145 起只用于拒绝「挂到主仓以外的仓」)。 */
    public boolean hasParentReference() {
        return parentReferenceSpecified;
    }
}
