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
}
