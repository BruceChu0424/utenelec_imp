package com.uten.imp.features.master.unit.dto;

import jakarta.validation.constraints.NotBlank;
import lombok.Getter;
import lombok.Setter;

/**
 * 基本单位新建/编辑请求（unit:edit）。
 *
 * <p>业务字段：名称(必填)/ 编号 / 状态(使用/禁用)/ 计量维度 / 等于哪种重量单位。
 * legacy_id/审计/软删不可改；在线新建不合成 legacy_id，关系只使用 UUID。
 * 新建与编辑共用本 DTO；计量设置按「请求即完整目标状态」保存。
 */
@Getter
@Setter
public class UnitSaveRequest {

    @NotBlank
    private String name;      // 单位名称（必填）
    private String code;      // 单位编号
    private String status;    // 使用/禁用
    /**
     * 计量维度：COUNT/MASS/LENGTH/AREA/VOLUME/OTHER；null 或空串 = 未设置(编辑时即清除)。
     * 合法值写入 unit_measurement_profiles(provenance=MANUAL_GOVERNANCE)。
     */
    private String measurementDimension;
    /**
     * 等于哪种重量单位(V745/ADR-135)：G/KG/T/JIN/LB/OZ，只能配合 MASS 维度；
     * null 或空串 = 不指定。维度不是 MASS 时必须为空(维度改离重量即清空)。
     */
    private String massUnitCode;
}
