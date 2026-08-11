package com.uten.imp.features.master.suppliercategory.dto;

import jakarta.validation.constraints.NotBlank;
import lombok.Getter;
import lombok.Setter;

import java.util.UUID;

@Getter
@Setter
public class SupplierCategorySaveRequest {
    // 编码：留空 → 服务端按 GF 前缀原子取号自动生成；非空 → 查重，冲突 409。
    // 历史重复码不拦截，唯一性仅对「今后新建」生效（应用层校验，无 DB 唯一索引）。
    private String code;

    @NotBlank
    private String name;

    private UUID parentId;      // 为空 = 顶级根

    private Integer sortOrder = 0;
}
