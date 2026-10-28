package com.uten.imp.common.web;

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
        @Size(max = 200) String bankAccount,
        @Size(max = 160) java.util.Map<@Size(max = 100) String, @Size(max = 200) String> columnSearch) {

    public ContactSensitiveFilter(String keyword, String mobile, String phone, String phone2, String bankAccount) {
        this(keyword, mobile, phone, phone2, bankAccount, java.util.Map.of());
    }

    public static final ContactSensitiveFilter NONE =
            new ContactSensitiveFilter(null, null, null, null, null);

    public static ContactSensitiveFilter orNone(ContactSensitiveFilter filter) {
        return filter == null ? NONE : filter;
    }

    /** The same transport bounds apply to list rows and count/category context reads. */
    public static void requireBoundedReadValues(String keyword, String mobile, String phone, String phone2, String bankAccount) {
        for (String value : new String[]{keyword, mobile, phone, phone2, bankAccount}) {
            if (value != null && value.length() > 200)
                throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,
                        "联系方式及关键词筛选值不能超过200个字符");
        }
    }
}
