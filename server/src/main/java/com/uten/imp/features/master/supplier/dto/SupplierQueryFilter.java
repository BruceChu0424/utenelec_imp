package com.uten.imp.features.master.supplier.dto;

import java.util.Set;
import java.util.UUID;

/**
 * 供应商列表查询条件值对象（聚合多字段筛选 + keyword + 空值字段集合）。
 *
 * <p>范式同 {@code com.uten.imp.features.master.goods.dto.GoodsQueryFilter}：
 * {@code nullFields} 存放"筛空值"的字段名（实体属性名），由 Service 端白名单校验后再生成
 * {@code is null} 谓词，避免任意属性路径注入。
 *
 * <p>19 个可筛字段：name/description/tday/place/empId/legalPerson/linkman/mobile/phone/
 * phone2/fax/postcode/address/bank/bankAccount/taxId/website/shipVia/shipAddress。
 * 主结账方式（无对应列）与损耗率（无对应列）不可筛。
 */
public record SupplierQueryFilter(
        UUID categoryId,
        String keyword,
        Set<String> nullFields,
        String name,
        String description,
        Integer tday,
        String place,
        String empId,
        String legalPerson,
        String linkman,
        String mobile,
        String phone,
        String phone2,
        String fax,
        String postcode,
        String address,
        String bank,
        String bankAccount,
        String taxId,
        String website,
        String shipVia,
        String shipAddress) {
}
