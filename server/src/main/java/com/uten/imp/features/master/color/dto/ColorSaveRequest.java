package com.uten.imp.features.master.color.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonSetter;
import lombok.Getter;
import lombok.Setter;

/**
 * 颜色新建/编辑请求（color:edit）。
 *
 * <p>业务字段：名称（必填）/ 编号 / 状态（使用/禁用）/ 备注。
 * legacy_id/审计/软删不可改；在线新建不合成 legacy_id，关系只使用 UUID。
 * 新建与编辑共用本 DTO。
 */
@Getter
@Setter
public class ColorSaveRequest {

    @NotBlank
    private String name;      // 颜色名称（必填）
    private String code;      // 颜色编号
    private String status;    // 使用/禁用
    @Size(max = 5000)
    private String remark;
    @JsonIgnore
    private boolean remarkPresent;

    @JsonSetter("remark")
    public void setRemark(String value) {
        remark = value;
        remarkPresent = true;
    }

    public boolean hasRemark() { return remarkPresent; }
}
