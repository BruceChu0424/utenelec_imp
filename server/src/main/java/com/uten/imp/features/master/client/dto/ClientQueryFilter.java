package com.uten.imp.features.master.client.dto;

import com.uten.imp.features.master.client.ClientSalesPaymentType;
import java.math.BigDecimal;
import java.util.Set;
import java.util.UUID;

/**
 * 客户列表查询条件值对象（聚合多字段筛选 + keyword + 空值字段集合）。
 *
 * <p>范式同 {@code com.uten.imp.features.master.goods.dto.GoodsQueryFilter}。
 * {@code nullFields} 存放"筛空值"的字段名（实体属性名），由 Service 端白名单校验后再
 * 生成 {@code is null} 谓词，避免任意属性路径。主结账方式 / 总监 无对应列，不在白名单。
 */
public record ClientQueryFilter(
        UUID categoryId,
        String keyword,
        Set<String> nullFields,
        String code,
        String name,
        String fullName,
        ClientSalesPaymentType salesPaymentType,
        String clientXz,
        Integer tday,
        String region,
        String placeId,
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
        BigDecimal credit,
        BigDecimal creditFloor,
        String website,
        boolean excludeLegacyFinanceStub,
        boolean selectableOnly) {
}
