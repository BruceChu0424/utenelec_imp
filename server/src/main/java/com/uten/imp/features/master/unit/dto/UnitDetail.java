package com.uten.imp.features.master.unit.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 基本单位详情（扁平主档，与列表项同字段，保留独立 DTO 与货品范式对齐）。
 */
@Getter
@AllArgsConstructor
public class UnitDetail {
    private UUID id;
    private String code;
    private String name;
    private String status;
    /** 仅旧库迁移溯源；在线新建为 null，关系身份始终使用 {@link #id}。 */
    private Integer legacyId;
    /**
     * 计量维度（2026-09-05 起，落 unit_measurement_profiles）：
     * COUNT 数量 / MASS 重量 / LENGTH 长度 / AREA 面积 / VOLUME 体积 / OTHER 其他。
     * null = 未设置。重量型单位（MASS）在收货/入库/检验里不再单独录实称重量——
     * 数量本身就是重量。
     */
    private String measurementDimension;
}
