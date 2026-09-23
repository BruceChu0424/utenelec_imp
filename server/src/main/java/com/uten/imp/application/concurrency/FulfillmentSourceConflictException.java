package com.uten.imp.application.concurrency;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

/**
 * 履约互斥守卫拒绝本次命令(409, 用户文案不变)。
 *
 * <p>{@link #retryable()} 为真表示这是「等锁期间别的事务先提交, 本事务预读的来源集合已过期」
 * 一类的瞬时冲突: 守卫在本命令第一笔写之前抛出, 事务整体回滚, 什么都没生效——
 * 用同一请求重新执行一遍(重新预读、重新按序拿锁)就是设计里说的「新请求使用新事实」。
 * {@link FulfillmentSourceConflictRetryInterceptor} 据此在最外层事务边界自动重跑(有总时长预算)。
 * 为假表示预锁顺序/归属被违反或足迹声明有缺口(编码或调用顺序问题), 重跑也不会变好, 直接 409。</p>
 */
public class FulfillmentSourceConflictException extends ApiException {

    public static final String USER_MESSAGE = "相关订单、库存或任务信息已变化，请刷新后重新提交；本次操作未生效";

    private final String internalReason;
    private final boolean retryable;

    public FulfillmentSourceConflictException(String internalReason, boolean retryable) {
        this(internalReason, retryable, USER_MESSAGE);
    }

    /** 需要换一句面向用户的提示时用(例如主仓协调锁等不到: 请稍后再试)。 */
    public FulfillmentSourceConflictException(String internalReason, boolean retryable, String userMessage) {
        super(ErrorCode.CONFLICT, userMessage);
        this.internalReason = internalReason;
        this.retryable = retryable;
    }

    /** 只进服务端日志, 永不回给客户端。 */
    public String internalReason() {
        return internalReason;
    }

    @Override
    public boolean retryable() {
        return retryable;
    }
}
