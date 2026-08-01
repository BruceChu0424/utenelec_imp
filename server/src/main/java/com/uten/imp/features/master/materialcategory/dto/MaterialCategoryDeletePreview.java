package com.uten.imp.features.master.materialcategory.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 分类删除预览：该分类（含自身）的子树规模，供前端在删除前弹红色确认框。
 *
 * <ul>
 *   <li>{@code descendantCount}：子树内除自身外的后代分类数（直接 + 间接子分类）。</li>
 *   <li>{@code goodsCount}：子树（含自身）下、未软删的货品数——删除分类会一并软删这些货品。</li>
 * </ul>
 */
@Getter
@AllArgsConstructor
public class MaterialCategoryDeletePreview {
    private UUID id;
    private int descendantCount;
    private long goodsCount;
}
