package com.uten.imp.features.master.unit.dto;

import jakarta.validation.constraints.NotBlank;
import lombok.Getter;
import lombok.Setter;

/**
 * 基本单位新建/编辑请求（unit:edit）。
 *
 * <p>仅 3 个业务字段：名称（必填）/ 编号 / 状态（使用/禁用）。
 * legacy_id/审计/软删不可改；在线新建不合成 legacy_id，关系只使用 UUID。
 * 新建与编辑共用本 DTO。
 */
@Getter
@Setter
public class UnitSaveRequest {

    @NotBlank
    private String name;      // 单位名称（必填）
    private String code;      // 单位编号
    private String status;    // 使用/禁用
}
