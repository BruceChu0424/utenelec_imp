package com.uten.imp.features.master.client.dto;

import jakarta.validation.constraints.Size;

/** 客户收货地址新增请求（地址必填；电话可空，随地址一起记忆）。 */
public record ClientShipAddressSaveRequest(
        @Size(max = 500, message = "收货地址不能超过 500 个字符") String address,
        @Size(max = 64, message = "联系电话不能超过 64 个字符") String linkPhone) {
}
