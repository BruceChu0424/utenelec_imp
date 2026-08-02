package com.uten.imp.features.master.mouldcategory.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 分类删除预览：该分类（含自身）的子树规模，供前端在删除前弹红色确认框。
 * 与 {@code MaterialCategoryDeletePreview} 同构（模具资料侧）。
 *
 * <ul>
 *   <li>{@code descendantCount}：子树内除自身外的后代分类数（直接 + 间接子分类）。</li>
 *   <li>{@code mouldCount}：子树（含自身）下、未软删的模具数——删除分类会一并软删这些模具。</li>
 * </ul>
 */
@Getter
@AllArgsConstructor
public class MouldCategoryDeletePreview {
    private UUID id;
    private int descendantCount;
    private long mouldCount;
}
