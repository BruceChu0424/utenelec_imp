package com.uten.imp.security;

import java.lang.annotation.Documented;
import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * /api/admin/** 下的写端点、以及响应里带明文临时密码的端点 (不论前缀) 默认都要再认证
 * ({@link RequiresStepUp}); 确实不需要的必须用本注解写明理由, 由 ArchitectureBoundaryTest 检查 (ADR-110)。
 */
@Documented
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface StepUpExempt {

    /** 为什么这个管理端写操作不需要重新输入密码 (给评审看的中文说明)。 */
    String value();
}
