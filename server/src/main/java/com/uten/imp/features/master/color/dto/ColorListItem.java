package com.uten.imp.features.master.color.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 颜色列表项（扁平主档，列表即全字段）。
 */
@Getter
@AllArgsConstructor
public class ColorListItem {
    private UUID id;
    private String code;
    private String name;
    private String status;
    /** 仅旧库迁移溯源；在线新建为 null，关系身份始终使用 {@link #id}。 */
    private Integer legacyId;
}
