package com.uten.imp.common.files.document;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.time.Duration;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.function.Function;

/**
 * 文件解析的全局闸门: 整个进程同一时间只解析一个客户文件(POI/PDFBox 占内存大), 每次解析有墙钟上限。
 *
 * <p>读取器在循环里定期调用 {@link Deadline#check()}; 超时抛 422「文件太复杂」, 不会无限占用工作线程。
 */
public final class DocumentParseGate {

    /** 单次解析墙钟上限。 */
    public static final Duration WALL_CLOCK = Duration.ofSeconds(60);
    /** 排队等待其他解析结束的上限。 */
    private static final Duration QUEUE_WAIT = Duration.ofSeconds(90);
    private static final Semaphore PERMIT = new Semaphore(1, true);

    private DocumentParseGate() {
    }

    /** 拿到解析许可后执行; 等不到许可抛 429, 超过墙钟由读取器抛 422。 */
    public static <T> T run(Function<Deadline, T> parse) {
        return run(WALL_CLOCK, parse);
    }

    static <T> T run(Duration wallClock, Function<Deadline, T> parse) {
        boolean acquired;
        try {
            acquired = PERMIT.tryAcquire(QUEUE_WAIT.toMillis(), TimeUnit.MILLISECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ApiException(ErrorCode.RATE_LIMITED, "正在读取其他文件, 请稍后再试");
        }
        if (!acquired) {
            throw new ApiException(ErrorCode.RATE_LIMITED, "正在读取其他文件, 请稍后再试");
        }
        try {
            return parse.apply(new Deadline(System.nanoTime() + wallClock.toNanos()));
        } finally {
            PERMIT.release();
        }
    }

    /** 本次解析的截止时间。 */
    public static final class Deadline {

        private final long deadlineNanos;

        Deadline(long deadlineNanos) {
            this.deadlineNanos = deadlineNanos;
        }

        /** 不设截止(测试或已在闸门内的嵌套调用)。 */
        public static Deadline none() {
            return new Deadline(Long.MAX_VALUE);
        }

        public boolean expired() {
            return deadlineNanos != Long.MAX_VALUE && System.nanoTime() - deadlineNanos > 0;
        }

        /** 超时抛 422。 */
        public void check() {
            if (expired()) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "文件内容太复杂, 读取超时了, 请只保留需要识别的部分后再试");
            }
        }
    }
}
