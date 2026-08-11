package com.uten.imp.features.master.materialcategory.dto;

import jakarta.validation.constraints.NotBlank;
import lombok.Getter;
import lombok.Setter;

import java.util.UUID;

@Getter
@Setter
public class MaterialCategorySaveRequest {
    // 编码：留空 → 服务端按 FL 前缀原子取号自动生成（如 FL000123）；
    // 非空 → 服务端查重，与现存 code 冲突则 409「编码已存在」。
    // 历史数据有大量重复 code（V31），唯一性只对「今后新建」生效（应用层校验，无 DB 唯一索引）。
    private String code;

    @NotBlank
    private String name;

    private UUID parentId;      // 为空 = 顶级根

    private Integer sortOrder = 0;
}
