package com.uten.imp.security;

import java.lang.annotation.Documented;
import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * 标在控制器方法上: 调用前必须出示本人本会话、空闲未满 5 分钟的再认证凭证
 * (请求头 {@value StepUpInterceptor#HEADER}, 由 POST /api/auth/step-up 输入登录密码换得)。
 * 缺失、空闲过期或不属于本会话一律 403 REAUTH_REQUIRED (ADR-110)。
 *
 * <p>校验续期时机: 参数绑定与 {@code @Valid} 校验、方法级权限判定都通过之后，进入方法体之前。
 * 校验失败或无权不会要求先输入密码。连续操作复用同一凭证；会话吊销、身份切换及空闲过期后重新验证。</p>
 */
@Documented
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface RequiresStepUp {
}
