package com.uten.imp.common.export;

import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * 导出进度的唯一汇报入口(2026-11-08)。
 *
 * <p>读取入口(主档游标、报表分页、审计)汇报「权威总行数 / 已读行数」, 写文件阶段汇报
 * 阶段; 两种导出共用:</p>
 * <ul>
 *   <li>同步导出: {@code ExportRateLimitInterceptor} 按请求头 {@link #HEADER} 注册一个
 *   可轮询的进度, 客户端在导出请求进行中定时 {@code GET /api/exports/progress/{id}}
 *   读取, 进度条随读取一步一步前进(服务端整份生成后才开始发送, 不能靠下载字节判断进度);</li>
 *   <li>后台导出任务: worker 打开不登记的作用域, 心跳把总数写入
 *   {@code report_export_jobs.total_rows}。</li>
 * </ul>
 * <p>没有作用域时所有汇报都是空操作, 不改变任何导出行为; 总数未知的导出不汇报总数,
 * 客户端显示不确定进度, 不伪造。只登记调用者本人的进度, 读取也只返回本人的。</p>
 */
public final class ExportProgress implements AutoCloseable {
    /** 客户端为一次同步导出生成的操作号(UUID)。 */
    public static final String HEADER = "X-Uten-Export-Operation";

    public enum Phase { READING, PACKAGING, ENCRYPTING }

    /** 一次轮询读到的进度; total 为 null 表示总数未知。 */
    public record Snapshot(long rows, Long total, String phase) { }

    private static final ThreadLocal<ExportProgress> CURRENT = new ThreadLocal<>();
    private static final ConcurrentHashMap<String, ExportProgress> REGISTRY = new ConcurrentHashMap<>();
    /** 同步导出全局并发本就有限(LegacyExportBudget), 登记表再设上限防滥用。 */
    private static final int MAX_REGISTERED = 256;

    private final ExportProgress previous;
    private final String key;
    private final AtomicLong rows = new AtomicLong();
    private volatile long total = -1;
    private volatile Phase phase = Phase.READING;
    private boolean closed;

    private ExportProgress(String key) {
        this.key = key;
        previous = CURRENT.get();
        CURRENT.set(this);
    }

    /** 不登记的作用域(后台导出任务的 worker 用)。 */
    public static ExportProgress open() { return new ExportProgress(null); }

    /** 登记一个可被本人轮询的作用域(同步导出请求用); 登记表满时退化为不登记。 */
    public static ExportProgress openRegistered(UUID user, UUID operation) {
        String key = key(user, operation);
        ExportProgress progress = new ExportProgress(REGISTRY.size() < MAX_REGISTERED ? key : null);
        if (progress.key != null && REGISTRY.putIfAbsent(progress.key, progress) != null) {
            // 同一操作号重复提交: 不顶替原进度, 本次作为不登记的作用域运行。
            progress.close();
            return new ExportProgress(null);
        }
        return progress;
    }

    /** 记下总行数; 只接受第一个非负值(后续分批不覆盖已确定的总数)。 */
    public static void announceTotal(long total) {
        ExportProgress current = CURRENT.get();
        if (current != null && total >= 0 && current.total < 0) current.total = total;
    }

    /** 已读行数, 单调不减。 */
    public static void rows(long rows) {
        ExportProgress current = CURRENT.get();
        if (current != null && rows >= 0) current.rows.accumulateAndGet(rows, Math::max);
    }

    public static void phase(Phase phase) {
        ExportProgress current = CURRENT.get();
        if (current != null && phase != null) current.phase = phase;
    }

    /** 当前线程作用域的总行数; 没有作用域或总数未知时为 null。 */
    public static Long currentTotal() {
        ExportProgress current = CURRENT.get();
        return current == null || current.total < 0 ? null : current.total;
    }

    /** 读取本人某次同步导出的进度; 不存在(未开始/已结束/非本人)时为空。 */
    public static Optional<Snapshot> snapshot(UUID user, UUID operation) {
        ExportProgress progress = REGISTRY.get(key(user, operation));
        if (progress == null) return Optional.empty();
        long total = progress.total;
        return Optional.of(new Snapshot(progress.rows.get(), total < 0 ? null : total, progress.phase.name()));
    }

    private static String key(UUID user, UUID operation) {
        if (user == null || operation == null) throw new IllegalArgumentException("Export progress needs its owner and operation");
        return user + ":" + operation;
    }

    @Override public void close() {
        if (closed) return;
        closed = true;
        if (key != null) REGISTRY.remove(key, this);
        if (CURRENT.get() == this) {
            if (previous == null) CURRENT.remove(); else CURRENT.set(previous);
        }
    }
}
