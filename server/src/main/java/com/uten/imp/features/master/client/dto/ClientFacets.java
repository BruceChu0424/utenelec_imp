package com.uten.imp.features.master.client.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.List;
import java.util.Map;

/**
 * 客户 facet 结果：某分类子树范围内，各筛选字段的 distinct 值桶 + 各字段空值计数。
 *
 * <p>前端据此渲染筛选栏下拉（"所有 / 空值(N) / 各具体值(N)"）。
 * 21 个字段（不含主结账方式 / 总监——V36 无对应列、不支持 facet 与 nullFields）。
 */
@Getter
@AllArgsConstructor
public class ClientFacets {
    private final List<FacetBucket> code;
    private final List<FacetBucket> name;
    private final List<FacetBucket> fullName;
    private final List<FacetBucket> clientXz;
    private final List<FacetBucket> tday;
    private final List<FacetBucket> region;
    private final List<FacetBucket> placeId;
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
    private final List<FacetBucket> credit;
    private final List<FacetBucket> website;
    private final Map<String, Long> nullCounts;
}
