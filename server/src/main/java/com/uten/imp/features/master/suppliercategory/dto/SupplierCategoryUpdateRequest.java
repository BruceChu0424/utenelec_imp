package com.uten.imp.features.master.suppliercategory.dto;

import jakarta.validation.constraints.NotBlank;
import lombok.Getter;
import lombok.Setter;

import java.util.UUID;

@Getter
@Setter
public class SupplierCategoryUpdateRequest {
    @NotBlank
    private String name;

    private UUID parentId;      // 改上级会做防成环校验 + 子树深度重算

    private Integer sortOrder;
}
