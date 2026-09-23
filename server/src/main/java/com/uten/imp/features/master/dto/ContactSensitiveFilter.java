package com.uten.imp.features.master.dto;

import jakarta.validation.constraints.Size;

/**
 * 客户/供应商列表里可能含个人/资金敏感信息的检索值 (security-19): 关键字 (会匹配手机号等)
 * 与按手机、电话、银行账号的列筛选。
 *
 * <p>这些值只能放在 POST 请求体里, 不得出现在 URL 查询串: 反向代理默认访问日志会连同 $request
 * 把查询串整行记下。GET 列表因此不再接受关键字, 带关键字的检索一律走 POST /search。</p>
 */
public record ContactSensitiveFilter(
        @Size(max = 200) String keyword,
        @Size(max = 200) String mobile,
        @Size(max = 200) String phone,
        @Size(max = 200) String phone2,
        @Size(max = 200) String bankAccount) {

    public static final ContactSensitiveFilter NONE =
            new ContactSensitiveFilter(null, null, null, null, null);

    public static ContactSensitiveFilter orNone(ContactSensitiveFilter filter) {
        return filter == null ? NONE : filter;
    }
}
