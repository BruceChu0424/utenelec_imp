package com.uten.imp.features.master.suppliercategory.dto;

import jakarta.validation.constraints.NotBlank;
import lombok.Getter;
import lombok.Setter;

import java.util.UUID;

@Getter
@Setter
public class SupplierCategorySaveRequest {
    @NotBlank
    private String code;        // 编码（不查重，允许重复）

    @NotBlank
    private String name;

    private UUID parentId;      // 为空 = 顶级根

    private Integer sortOrder = 0;
}
