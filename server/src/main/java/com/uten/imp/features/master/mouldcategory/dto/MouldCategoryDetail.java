package com.uten.imp.features.master.mouldcategory.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

@Getter
@AllArgsConstructor
public class MouldCategoryDetail {
    private UUID id;
    private String code;
    private String name;
    private Integer level;
    private Integer legacyId;
    private UUID parentId;
    private String parentName;
    private Integer sortOrder;
    private String path;
    private long childCount;
}
