package com.uten.imp.features.master.supplier.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.List;
import java.util.Map;

/**
 * 供应商 facet 结果：某分类子树范围内，各筛选字段的 distinct 值桶 + 各字段空值计数。
 *
 * <p>前端据此渲染筛选栏下拉（"所有 / 空值(N) / 各具体值(N)"）。
 * 与 {@code com.uten.imp.features.master.goods.dto.GoodsFacets} 同构，字段换成供应商相关。
 * 主结账方式（无对应列）与损耗率（无对应列）不在此处暴露。
 */
@Getter
@AllArgsConstructor
public class SupplierFacets {
    private final List<FacetBucket> name;
    private final List<FacetBucket> description;
    private final List<FacetBucket> tday;
    private final List<FacetBucket> place;
    private final List<FacetBucket> empId;
    private final List<FacetBucket> legalPerson;
    private final List<FacetBucket> linkman;
    private final List<FacetBucket> mobile;
    private final List<FacetBucket> phone;
    private final List<FacetBucket> phone2;
    private final List<FacetBucket> fax;
    private final List<FacetBucket> postcode;
    private final List<FacetBucket> address;
    private final List<FacetBucket> bank;
    private final List<FacetBucket> bankAccount;
    private final List<FacetBucket> taxId;
    private final List<FacetBucket> website;
    private final List<FacetBucket> shipVia;
    private final List<FacetBucket> shipAddress;
    private final Map<String, Long> nullCounts;
}
