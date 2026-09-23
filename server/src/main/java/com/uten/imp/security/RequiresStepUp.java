package com.uten.imp.security;

import java.lang.annotation.Documented;
import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * 标在控制器方法上: 调用前必须出示本人本会话、5 分钟内签发且未用过的再认证凭证
 * (请求头 {@value StepUpInterceptor#HEADER}, 由 POST /api/auth/step-up 输入登录密码换得)。
 * 缺失、过期、已用过或不属于本会话一律 403 REAUTH_REQUIRED (ADR-110)。
 *
 * <p>核销时机: 参数绑定与 {@code @Valid} 校验、方法级权限判定都通过之后, 进入方法体之前
 * (校验失败或无权的请求不消耗凭证, 也不会先要求输入密码)。凭证用一次即作废; 业务随后失败
 * 也需要重新确认密码。</p>
 */
@Documented
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface RequiresStepUp {
}
