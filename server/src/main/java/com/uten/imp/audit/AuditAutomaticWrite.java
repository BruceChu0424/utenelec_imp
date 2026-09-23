package com.uten.imp.audit;

import java.lang.annotation.Documented;
import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * 声明一个写端点由客户端自动发起、只维护会话或界面状态(心跳、已读回执、界面偏好),
 * 成功时不生成语义业务事件; 失败照常记录(ADR-105)。
 *
 * <p>只用于不代表人的业务决定的写入。取代原先手工维护的请求路径降噪清单:
 * 声明跟着控制器方法走, 改路径不会漏登。
 */
@Documented
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.METHOD)
public @interface AuditAutomaticWrite {

    /** 为什么这个写入不算人的操作。 */
    String value();
}
