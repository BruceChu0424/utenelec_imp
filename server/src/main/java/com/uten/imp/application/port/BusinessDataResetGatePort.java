package com.uten.imp.application.port;

/**
 * 业务数据清空的排水闸(实现: features/admin/systemtest 的 BusinessDataResetDrainGate)。
 *
 * <p>给不经过 HTTP 过滤器的后台写入者(如 AI 任务工作线程)用: 每个<b>短</b>数据库事务前
 * {@link #tryEnter()}、结束后在 finally 里 {@link #leave()}; 绝不能跨网络调用或整个任务持有,
 * 否则清空排水会超时失败。长任务在阶段之间检查 {@link #blockingNewRequests()}, 为 true 即中止。
 */
public interface BusinessDataResetGatePort {

    /** 非清空期间进入在途计数并返回 true; 清空排水/进行中返回 false(调用方不得写库)。 */
    boolean tryEnter();

    /** 与成功的 {@link #tryEnter()} 成对调用。 */
    void leave();

    /** 清空排水或进行中: 新的业务写入应当拒绝或中止。 */
    boolean blockingNewRequests();
}
