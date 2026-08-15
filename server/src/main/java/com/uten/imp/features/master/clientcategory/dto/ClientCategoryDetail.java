package com.uten.imp.features.master.clientcategory.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 分类详情 API 投影：id/parentId 是唯一关系键；code 是系统只读显示号；remark 可编辑；
 * legacyCodeSnapshot/legacyId 仅作迁移证据；codePrefix 是本级显式值，effectivePrefix 是继承解析结果。
 */
@Getter
@AllArgsConstructor
public class ClientCategoryDetail {
    private UUID id;
    private String code;
    private String remark;
    private String legacyCodeSnapshot;
    private String codePrefix;
    private String effectivePrefix;
    private String name;
    private Integer level;
    private Integer legacyId;
    private UUID parentId;
    private String parentName;
    private Integer sortOrder;
    private String path;
    private long childCount;
    private long version;
    private boolean systemManaged;
}
