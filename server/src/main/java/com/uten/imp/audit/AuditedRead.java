package com.uten.imp.audit;

import java.lang.annotation.Documented;
import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * 声明一个成功的读取请求也要留请求级审计(ADR-105)。
 *
 * <p>成功的 GET/HEAD 默认不写审计: 角标、轮询、列表翻页占了请求审计的九成以上, 却回答不了
 * 「谁看过什么」。需要追溯的敏感读取只有两类: 业务服务里已经显式记录的详情查看/下载/审计查询
 * (由 {@link AuditDetailViewRecorder}、{@link AuditService#logSuccessfulAuditView} 等写入),
 * 以及没有详情事件、但会一次返回个人敏感资料的读取端点, 后者在控制器方法或类上标注本注解。
 * 是否留痕只由服务端声明决定, 不看客户端请求头。
 */
@Documented
@Retention(RetentionPolicy.RUNTIME)
@Target({ElementType.METHOD, ElementType.TYPE})
public @interface AuditedRead {

    /** 为什么这个读取需要追溯(写给审计复核的人看)。 */
    String value();
}
