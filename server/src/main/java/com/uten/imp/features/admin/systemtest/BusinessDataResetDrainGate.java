package com.uten.imp.features.admin.systemtest;

import com.uten.imp.application.port.BusinessDataResetGatePort;
import org.springframework.stereotype.Component;

import java.util.concurrent.TimeUnit;

/**
 * 业务数据清空期间的应用排水闸：把清空需要的「没有其它请求在写」这一前提搬进运行中的应用。
 *
 * <p>清空事务要对 222 张业务表拿 ACCESS EXCLUSIVE 锁，任何并发业务写都会让
 * TRUNCATE 在 lock_timeout 上失败（或更糟：在清空提交后补写残留行）。因此清空开始前：</p>
 * <ol>
 *   <li>状态切到 DRAINING：{@link BusinessDataResetDrainFilter} 对除清空端点外的
 *       全部 /api 请求直接回 503，不再进入控制器/事务；</li>
 *   <li>等待已进入的在途请求计数归零（带超时，超时放弃清空、整体回到 IDLE）；</li>
 *   <li>状态切到 RESETTING，执行清空；完成（含回滚）后回到 IDLE 放行流量。</li>
 * </ol>
 *
 * <p>清空本身在请求线程同步执行，不走本闸计数（清空端点路径在过滤器里豁免），
 * 避免自己等自己。所有状态迁移与计数都在同一监视器上完成，无 check-then-act 竞态。</p>
 */
@Component
public class BusinessDataResetDrainGate implements BusinessDataResetGatePort {

    private enum Phase { IDLE, DRAINING, RESETTING }

    private Phase phase = Phase.IDLE;
    private int inFlight = 0;

    /** 过滤器调用：非清空期间的请求进入在途计数。调用方必须保证 finally 里 {@link #leave()}。 */
    @Override
    public synchronized boolean tryEnter() {
        if (phase != Phase.IDLE) return false;
        inFlight++;
        return true;
    }

    @Override
    public synchronized void leave() {
        inFlight--;
        notifyAll();
    }

    /** 清空期间是否应拒绝新的普通 API 请求。 */
    @Override
    public synchronized boolean blockingNewRequests() {
        return phase != Phase.IDLE;
    }

    /** Result of {@link #beginDrain}: only {@code STARTED} hands {@link #endReset()} to the caller. */
    public enum DrainOutcome { STARTED, ANOTHER_RESET, IN_FLIGHT_TIMEOUT }

    /**
     * 开始排水并等待在途请求清零。
     *
     * @return STARTED 表示排水完成，调用方可以执行清空并负责 {@link #endReset()}；ANOTHER_RESET 表示已有清空在进行；
     *         IN_FLIGHT_TIMEOUT 表示等待在途请求超时(已回到 IDLE)
     */
    public synchronized DrainOutcome beginDrain(long timeoutMillis) throws InterruptedException {
        if (phase != Phase.IDLE) {
            return DrainOutcome.ANOTHER_RESET;
        }
        phase = Phase.DRAINING;
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis);
        boolean resetStarted = false;
        try {
            while (inFlight > 0) {
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0) {
                    return DrainOutcome.IN_FLIGHT_TIMEOUT;
                }
                TimeUnit.NANOSECONDS.timedWait(this, remaining);
            }
            phase = Phase.RESETTING;
            resetStarted = true;
            return DrainOutcome.STARTED;
        } finally {
            // The caller owns endReset only after a successful drain. In
            // particular, an interrupted wait must not leave all APIs blocked.
            if (!resetStarted) {
                phase = Phase.IDLE;
                notifyAll();
            }
        }
    }

    /** 清空结束（成功或失败）后放行流量。 */
    public synchronized void endReset() {
        if (phase != Phase.IDLE) {
            phase = Phase.IDLE;
        }
        notifyAll();
    }
}
