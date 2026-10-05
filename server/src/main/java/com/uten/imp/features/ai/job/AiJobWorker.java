package com.uten.imp.features.ai.job;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiCompletionPort;
import com.uten.imp.application.port.AiCompletionPort.AiCallException;
import com.uten.imp.application.port.AiCompletionPort.AiErrorCategory;
import com.uten.imp.application.port.AiJobHandler;
import com.uten.imp.application.port.BusinessDataResetGatePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.ai.AiPermissions;
import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.features.ai.gateway.AiGateway;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SubmitterPrincipalRestorer;
import jakarta.annotation.PreDestroy;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.annotation.Profile;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContext;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.event.TransactionPhase;
import org.springframework.transaction.event.TransactionalEventListener;
import org.springframework.transaction.support.TransactionCallback;
import org.springframework.transaction.support.TransactionTemplate;

import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Pattern;

/**
 * AI 识别任务的后台处理(ADR-133; 只在本地实例运行, 云端实例提交的任务也由这里经轮询接手)。
 *
 * <p>专用线程池(默认 2 个守护线程 {@code ai-job-N}, 有界等待队列 8, 满了直接放弃唤醒 —— 真正的队列在数据库,
 * 5 秒轮询兜底)。认领用 {@code FOR UPDATE SKIP LOCKED} 的独立短事务。每个短事务都经过业务数据清空排水闸
 * ({@link BusinessDataResetGatePort#tryEnter()}/{@code leave()}), 排水闸从不跨网络调用或整个任务持有;
 * 阶段之间发现系统正在清空就中止。
 *
 * <p>租约: 认领、阶段报告与 AI 调用前后都续租; 一次 AI 调用可能比租约还长(等名额 + 服务商超时 + 重试一次),
 * 所以调用期间由守护线程 {@code ai-job-lease} 每隔租约的 1/4(最长 60 秒)续租。处理器自己的解析阶段不续租 ——
 * 卡死的解析仍会在租约过期后按坏文件处理。认领令牌: 每次认领 attempts 加一, 工作线程的每一次写入都带
 * {@code attempts = 这次认领的值}; 租约万一过期被重新认领, 旧线程的写入影响 0 行即安静停止, 不会改写新一次认领。
 *
 * <p>处理前用 {@link SubmitterPrincipalRestorer} 按提交时的授权戳重建提交人主体放进本线程的
 * SecurityContext(finally 清除); 账号状态或权限变化即失败「账号权限已变化, 请重新识别」, 从不用系统或超管身份。
 * 任何终态更新都在同一语句里清空上传文件; 更新影响 0 行(任务被取消、清理、清库或已被重新认领)就安静停止。
 *
 * <p>失败原因给业务人员看: 处理器的 {@link ApiException} 用它的消息; AI 调用失败按错误类别换成不含技术细节的
 * 说法(类别与 HTTP 状态只记服务端日志); 其他异常一律「识别失败, 请稍后重试」。
 */
@Slf4j
@Component
@Profile("!cloud")
public class AiJobWorker implements AutoCloseable {

    static final String PRINCIPAL_CHANGED_MESSAGE = "账号权限已变化, 请重新识别";
    static final String RESETTING_MESSAGE = "系统正在重置数据, 请稍后重试";
    static final String GENERIC_FAILURE_MESSAGE = "识别失败, 请稍后重试";
    static final String CANCELLED_MESSAGE = "识别已取消";
    static final String NO_AI_USE_MESSAGE = "没有使用 AI 识别的权限";
    static final String CALL_CAP_MESSAGE = "这次识别调用 AI 的次数已达上限";
    static final String AI_BUSY_MESSAGE = "AI 服务暂时繁忙或今日额度已用完, 请稍后再试";
    static final String AI_UNAVAILABLE_MESSAGE = "AI 服务暂时不可用, 请联系管理员";
    static final int MAX_RESULT_CHARS = 8 * 1024 * 1024;

    /** 平台自己抛出的、本来就是给业务人员看的 BLOCKED 消息; 其余 BLOCKED(地址被拦等)是给管理员看的。 */
    private static final Set<String> PLAIN_BLOCKED_MESSAGES = Set.of(CANCELLED_MESSAGE, NO_AI_USE_MESSAGE,
            CALL_CAP_MESSAGE, RESETTING_MESSAGE, AiGateway.VISION_UNSUPPORTED_MESSAGE);
    private static final Pattern STAGE = Pattern.compile("^[A-Z][A-Z0-9_]{0,47}$");
    /** 处理器随 ApiException 给出的业务错误码(fieldErrors 里 field = errorCode), 写进 ai_jobs.error_code。 */
    static final String ERROR_CODE_FIELD = "errorCode";
    private static final Pattern ERROR_CODE = STAGE;
    private static final long CANCEL_CHECK_INTERVAL_NANOS = TimeUnit.SECONDS.toNanos(2);

    private final AiJobRepository repository;
    private final AiJobHandlerRegistry registry;
    private final SubmitterPrincipalRestorer restorer;
    private final AiCompletionPort completion;
    private final BusinessDataResetGatePort resetGate;
    private final AiProperties properties;
    private final ObjectMapper objectMapper;
    private final TransactionTemplate requiresNew;
    private final ExecutorService executor;
    private final ScheduledThreadPoolExecutor leaseKeeper;
    private final int workers;
    private final Object lock = new Object();
    /** 处理中的任务 → 这次认领的令牌(attempts)。 */
    private final Map<UUID, Integer> inFlight = new ConcurrentHashMap<>();
    private int running;
    private boolean wakePending;
    private boolean closed;

    @Autowired
    public AiJobWorker(AiJobRepository repository, AiJobHandlerRegistry registry,
                       SubmitterPrincipalRestorer restorer, AiCompletionPort completion,
                       BusinessDataResetGatePort resetGate, AiProperties properties, ObjectMapper objectMapper,
                       PlatformTransactionManager transactionManager) {
        this(repository, registry, restorer, completion, resetGate, properties, objectMapper, transactionManager,
                newExecutor(properties));
    }

    AiJobWorker(AiJobRepository repository, AiJobHandlerRegistry registry, SubmitterPrincipalRestorer restorer,
                AiCompletionPort completion, BusinessDataResetGatePort resetGate, AiProperties properties,
                ObjectMapper objectMapper, PlatformTransactionManager transactionManager, ExecutorService executor) {
        this.repository = repository;
        this.registry = registry;
        this.restorer = restorer;
        this.completion = completion;
        this.resetGate = resetGate;
        this.properties = properties;
        this.objectMapper = objectMapper;
        this.requiresNew = new TransactionTemplate(transactionManager);
        this.requiresNew.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        this.requiresNew.setTimeout(30);
        this.executor = executor;
        this.leaseKeeper = newLeaseKeeper();
        this.workers = Math.max(1, properties.getJobWorkers());
    }

    private static ExecutorService newExecutor(AiProperties properties) {
        int workers = Math.max(1, properties.getJobWorkers());
        AtomicInteger sequence = new AtomicInteger();
        return new ThreadPoolExecutor(workers, workers, 0, TimeUnit.MILLISECONDS,
                new ArrayBlockingQueue<>(Math.max(1, properties.getJobQueueCapacity())),
                runnable -> {
                    Thread thread = new Thread(runnable, "ai-job-" + sequence.incrementAndGet());
                    thread.setDaemon(true);
                    return thread;
                },
                new ThreadPoolExecutor.AbortPolicy());
    }

    private static ScheduledThreadPoolExecutor newLeaseKeeper() {
        ScheduledThreadPoolExecutor keeper = new ScheduledThreadPoolExecutor(1, runnable -> {
            Thread thread = new Thread(runnable, "ai-job-lease");
            thread.setDaemon(true);
            return thread;
        });
        keeper.setRemoveOnCancelPolicy(true);
        keeper.setExecuteExistingDelayedTasksAfterShutdownPolicy(false);
        return keeper;
    }

    /** 租约秒数(每次读取配置, 运维改配置后重启生效; 测试可临时调短)。 */
    private int leaseSeconds() {
        return Math.max(1, properties.getJobLeaseSeconds());
    }

    /** AI 调用期间的续租间隔: 租约的 1/4, 不短于 0.2 秒、不长于 60 秒。 */
    long leaseRenewMillis() {
        return Math.max(200L, Math.min(60_000L, leaseSeconds() * 1000L / 4));
    }

    /** 新任务提交后唤醒。 */
    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    public void onSubmitted(AiJobSubmittedEvent ignored) {
        wake();
    }

    /** 定时轮询入口: 回收过期租约, 然后唤醒。 */
    public void recoverAndWake() {
        try {
            int recovered = shortTx(status -> repository.recoverExpiredLeases());
            if (recovered > 0) {
                log.warn("Recovered {} AI job(s) whose worker lease expired", recovered);
            }
        } catch (ResetDraining e) {
            return;
        } catch (RuntimeException e) {
            log.warn("AI job lease recovery failed: {}", e.getClass().getSimpleName());
        }
        wake();
    }

    /** 唤醒处理线程(不超过线程数)。 */
    public void wake() {
        synchronized (lock) {
            if (closed) {
                return;
            }
            wakePending = true;
            while (running < workers) {
                running++;
                try {
                    executor.execute(this::drainLoop);
                } catch (RejectedExecutionException e) {
                    running--;
                    break;
                }
            }
        }
    }

    private void drainLoop() {
        try {
            while (true) {
                synchronized (lock) {
                    if (closed) {
                        return;
                    }
                    wakePending = false;
                }
                boolean worked;
                try {
                    worked = processNext();
                } catch (ResetDraining e) {
                    return;
                } catch (RuntimeException e) {
                    log.warn("AI job worker loop failed: {}", e.getClass().getSimpleName());
                    return;
                }
                if (!worked) {
                    synchronized (lock) {
                        if (closed || !wakePending) {
                            return;
                        }
                    }
                }
            }
        } finally {
            synchronized (lock) {
                running--;
            }
        }
    }

    /** 认领并处理一个任务; 没有可认领的返回 false。 */
    boolean processNext() {
        if (resetGate.blockingNewRequests()) {
            return false;
        }
        Optional<AiJobRepository.ClaimedJob> claimed = shortTx(status -> repository.claimNext(leaseSeconds()));
        if (claimed.isEmpty()) {
            return false;
        }
        AiJobRepository.ClaimedJob job = claimed.get();
        inFlight.put(job.id(), job.attempts());
        try {
            process(job);
        } finally {
            inFlight.remove(job.id(), job.attempts());
        }
        return true;
    }

    void process(AiJobRepository.ClaimedJob job) {
        AiJobHandler handler = registry.find(job.kind()).orElse(null);
        if (handler == null) {
            finishFailed(job, "UNKNOWN_KIND", "这种识别任务已下线, 请重新上传");
            return;
        }
        AuthUser principal;
        try {
            principal = shortTx(status -> restorer.restore(job.submittedByUser(), job.submittedAuthVersion(),
                    job.submittedAuthEpoch()));
        } catch (SubmitterPrincipalRestorer.PrincipalChangedException e) {
            log.info("AI job {} stopped: submitter principal changed ({})", job.id(), e.reason());
            finishFailed(job, "PRINCIPAL_CHANGED", PRINCIPAL_CHANGED_MESSAGE);
            return;
        } catch (ResetDraining e) {
            return;
        } catch (RuntimeException e) {
            log.warn("AI job {} could not restore its submitter: {}", job.id(), e.getClass().getSimpleName());
            finishFailed(job, "INTERNAL", GENERIC_FAILURE_MESSAGE);
            return;
        }

        Execution execution = new Execution(job, principal);
        SecurityContext context = SecurityContextHolder.createEmptyContext();
        context.setAuthentication(new UsernamePasswordAuthenticationToken(principal, null, principal.getAuthorities()));
        Map<String, Object> result = null;
        Throwable failure = null;
        SecurityContextHolder.setContext(context);
        try {
            result = handler.process(execution);
        } catch (Throwable error) {
            failure = error;
        } finally {
            SecurityContextHolder.clearContext();
        }

        if (execution.vanished) {
            return;
        }
        synchronized (lock) {
            if (closed && failure != null) {
                releaseForShutdown(job.id(), job.attempts());
                return;
            }
        }
        if (execution.resetDraining || resetGate.blockingNewRequests()) {
            finishFailed(job, "RESETTING", RESETTING_MESSAGE);
            return;
        }
        if (failure != null) {
            finishWithFailure(job, execution, failure);
            return;
        }
        if (execution.cancelRequested) {
            finish(job, status -> repository.finishCancelled(job.id(), job.attempts()));
            return;
        }
        String json;
        try {
            json = objectMapper.writeValueAsString(result == null ? Map.of() : result);
        } catch (IOException e) {
            log.error("AI job {} ({}) produced a result that cannot be serialized", job.id(), job.kind());
            finishFailed(job, "INTERNAL", GENERIC_FAILURE_MESSAGE);
            return;
        }
        if (json.length() > MAX_RESULT_CHARS) {
            finishFailed(job, "RESULT_TOO_LARGE", "识别结果太大, 请把文件拆小后再上传");
            return;
        }
        finish(job, status -> repository.finishSucceeded(job.id(), job.attempts(), json));
    }

    private void finishWithFailure(AiJobRepository.ClaimedJob job, Execution execution, Throwable failure) {
        if (failure instanceof ApiException api) {
            finishFailed(job, errorCodeOf(api), api.getMessage());
        } else if (failure instanceof AiCallException ai) {
            if (execution.cancelRequested && ai.category() == AiErrorCategory.BLOCKED) {
                finish(job, status -> repository.finishCancelled(job.id(), job.attempts()));
            } else {
                log.info("AI job {} ({}) failed on an AI call: category={}, status={}", job.id(), job.kind(),
                        ai.category(), ai.httpStatus());
                finishFailed(job, "AI_" + ai.category().name(), plainAiFailureMessage(ai));
            }
        } else if (execution.cancelRequested) {
            finish(job, status -> repository.finishCancelled(job.id(), job.attempts()));
        } else {
            log.error("AI job {} ({}) failed", job.id(), job.kind(), redacted(failure));
            finishFailed(job, "INTERNAL", GENERIC_FAILURE_MESSAGE);
        }
    }

    /**
     * 处理器 ApiException 的错误码: fieldErrors 里 {@code errorCode} 字段给出的业务码(如 AI_REQUIRED、
     * AI_VISION_UNAVAILABLE, 大写下划线、不超过 48 字符)优先, 前端据此给出对应的下一步; 没有或不合格式时
     * 用 ApiException 自己的错误类别名(BUSINESS / VALIDATION_FAILED ...)。
     */
    static String errorCodeOf(ApiException failure) {
        if (failure.getFieldErrors() != null) {
            for (com.uten.imp.common.web.ApiError.FieldError field : failure.getFieldErrors()) {
                if (field != null && ERROR_CODE_FIELD.equals(field.field()) && field.message() != null
                        && ERROR_CODE.matcher(field.message()).matches()) {
                    return field.message();
                }
            }
        }
        return failure.getCode().name();
    }

    /**
     * AI 调用失败时给业务人员看的说法: 不出现服务商、模型、HTTP 状态或服务商原文(那些是管理员在「AI 服务」设置页
     * 与调用记录里看的)。平台自己的 BLOCKED 提示(已取消、无权限、次数上限、清库中、不支持图片)原样保留。
     */
    static String plainAiFailureMessage(AiCallException failure) {
        if (failure.category() == AiErrorCategory.BLOCKED && PLAIN_BLOCKED_MESSAGES.contains(failure.getMessage())) {
            return failure.getMessage();
        }
        return switch (failure.category()) {
            case RATE_LIMIT, QUOTA -> AI_BUSY_MESSAGE;
            case AUTH, NOT_FOUND, BAD_REQUEST, BLOCKED, UNAVAILABLE -> AI_UNAVAILABLE_MESSAGE;
            case TIMEOUT, NETWORK, SERVER, INVALID_RESPONSE -> GENERIC_FAILURE_MESSAGE;
        };
    }

    private void finishFailed(AiJobRepository.ClaimedJob job, String code, String message) {
        finish(job, status -> repository.finishFailed(job.id(), job.attempts(), code, message));
    }

    private void finish(AiJobRepository.ClaimedJob job, TransactionCallback<Integer> update) {
        try {
            Integer rows = shortTx(update);
            if (rows == null || rows == 0) {
                log.debug("AI job {} (attempt {}) was no longer held by this worker when finishing", job.id(),
                        job.attempts());
            }
        } catch (ResetDraining e) {
            // 表会被清空, 无需也不能再写。
        } catch (RuntimeException e) {
            log.warn("AI job {} terminal update failed: {}; lease recovery will close it", job.id(),
                    e.getClass().getSimpleName());
        }
    }

    private void releaseForShutdown(UUID id, int attempt) {
        try {
            requiresNew.execute(status -> repository.releaseForShutdown(id, attempt));
        } catch (RuntimeException e) {
            log.warn("AI job {} could not be released on shutdown: {}", id, e.getClass().getSimpleName());
        }
    }

    private <T> T shortTx(TransactionCallback<T> work) {
        if (!resetGate.tryEnter()) {
            throw new ResetDraining();
        }
        try {
            return requiresNew.execute(work);
        } finally {
            resetGate.leave();
        }
    }

    /** 日志只留异常类型与调用栈, 不留消息(可能带有客户文件内容)。 */
    static Throwable redacted(Throwable original) {
        RuntimeException copy = new RuntimeException(original.getClass().getName());
        copy.setStackTrace(original.getStackTrace());
        Throwable cause = original.getCause();
        if (cause != null && cause != original) {
            RuntimeException causeCopy = new RuntimeException("caused by " + cause.getClass().getName());
            causeCopy.setStackTrace(cause.getStackTrace());
            copy.initCause(causeCopy);
        }
        return copy;
    }

    @PreDestroy
    @Override
    public void close() {
        synchronized (lock) {
            if (closed) {
                return;
            }
            closed = true;
        }
        executor.shutdownNow();
        try {
            executor.awaitTermination(10, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        leaseKeeper.shutdownNow();
        for (Map.Entry<UUID, Integer> job : Map.copyOf(inFlight).entrySet()) {
            releaseForShutdown(job.getKey(), job.getValue());
        }
    }

    /** 清空排水期间不能开事务。 */
    static final class ResetDraining extends RuntimeException {
        ResetDraining() {
            super("business data reset is draining", null, false, false);
        }
    }

    /** 一次处理的上下文(处理器看到的 {@link AiJobHandler.AiJobContext})。 */
    final class Execution implements AiJobHandler.AiJobContext {
        private final AiJobRepository.ClaimedJob job;
        private final AuthUser principal;
        private final Map<String, String> params;
        private final AiJobHandler.AiJobInput input;
        private final int maxCalls;
        private volatile int aiCalls;
        private volatile boolean vanished;
        private volatile boolean resetDraining;
        private volatile boolean cancelRequested;
        private volatile long lastCancelCheck = System.nanoTime();

        Execution(AiJobRepository.ClaimedJob job, AuthUser principal) {
            this.job = job;
            this.principal = principal;
            this.params = parseParams(job.paramsJson());
            this.input = new AiJobHandler.AiJobInput(job.inputName(), job.inputContentType(), job.inputKind(),
                    job.inputSize(), job.inputBytes() == null ? new byte[0] : job.inputBytes(), job.inputSha256());
            this.maxCalls = Math.max(0, properties.getMaxCallsPerJob());
            this.aiCalls = job.aiCalls();
        }

        @Override
        public UUID jobId() {
            return job.id();
        }

        @Override
        public String kind() {
            return job.kind();
        }

        @Override
        public Map<String, String> params() {
            return params;
        }

        @Override
        public AiJobHandler.AiJobInput input() {
            return input;
        }

        @Override
        public UUID submittedByUser() {
            return job.submittedByUser();
        }

        @Override
        public UUID submittedByEmployee() {
            return job.submittedByEmployee();
        }

        @Override
        public void progress(String stage, int percent) {
            String safeStage = stage != null && STAGE.matcher(stage).matches() ? stage : null;
            touch(safeStage, Math.max(0, Math.min(100, percent)));
        }

        /** 写阶段/进度(为空表示不改)并续租, 顺便读回取消标记。 */
        private void touch(String stage, Integer percent) {
            if (vanished || resetDraining) {
                return;
            }
            if (resetGate.blockingNewRequests()) {
                resetDraining = true;
                return;
            }
            try {
                Optional<Boolean> cancel = shortTx(status -> repository.progress(job.id(), job.attempts(), stage,
                        percent, leaseSeconds()));
                if (cancel.isEmpty()) {
                    vanished = true;
                } else if (Boolean.TRUE.equals(cancel.get())) {
                    cancelRequested = true;
                }
                lastCancelCheck = System.nanoTime();
            } catch (ResetDraining e) {
                resetDraining = true;
            } catch (RuntimeException e) {
                log.warn("AI job {} progress update failed: {}", job.id(), e.getClass().getSimpleName());
            }
        }

        /** AI 调用期间的续租(在 ai-job-lease 线程上执行; 任何异常都不能让定时任务停掉)。 */
        private void renewLease() {
            try {
                touch(null, null);
            } catch (Throwable error) {
                log.warn("AI job {} lease renewal failed: {}", job.id(), error.getClass().getSimpleName());
            }
        }

        private ScheduledFuture<?> keepLeaseDuringCall() {
            long period = leaseRenewMillis();
            try {
                return leaseKeeper.scheduleWithFixedDelay(this::renewLease, period, period, TimeUnit.MILLISECONDS);
            } catch (RejectedExecutionException e) {
                return null;
            }
        }

        @Override
        public boolean cancelled() {
            if (vanished || resetDraining || cancelRequested) {
                return true;
            }
            if (resetGate.blockingNewRequests()) {
                resetDraining = true;
                return true;
            }
            if (System.nanoTime() - lastCancelCheck >= CANCEL_CHECK_INTERVAL_NANOS) {
                lastCancelCheck = System.nanoTime();
                try {
                    Optional<Boolean> cancel = shortTx(status -> repository.cancelRequested(job.id(),
                            job.attempts()));
                    if (cancel.isEmpty()) {
                        vanished = true;
                    } else if (Boolean.TRUE.equals(cancel.get())) {
                        cancelRequested = true;
                    }
                } catch (ResetDraining e) {
                    resetDraining = true;
                } catch (RuntimeException e) {
                    log.warn("AI job {} cancel check failed: {}", job.id(), e.getClass().getSimpleName());
                }
            }
            return vanished || resetDraining || cancelRequested;
        }

        @Override
        public int remainingAiCalls() {
            return Math.max(0, maxCalls - aiCalls);
        }

        @Override
        public AiCompletionPort.AiCompletionResult completeJson(AiCompletionPort.AiCompletionRequest request) {
            if (cancelled()) {
                throw new AiCallException(AiErrorCategory.BLOCKED, CANCELLED_MESSAGE);
            }
            if (!holdsAiUse()) {
                throw new AiCallException(AiErrorCategory.BLOCKED, NO_AI_USE_MESSAGE);
            }
            int count;
            try {
                count = shortTx(status -> repository.incrementAiCalls(job.id(), job.attempts(), maxCalls,
                        leaseSeconds()));
            } catch (ResetDraining e) {
                resetDraining = true;
                throw new AiCallException(AiErrorCategory.BLOCKED, RESETTING_MESSAGE);
            }
            if (count == -1) {
                vanished = true;
                throw new AiCallException(AiErrorCategory.BLOCKED, CANCELLED_MESSAGE);
            }
            if (count == -2) {
                throw new AiCallException(AiErrorCategory.BLOCKED, CALL_CAP_MESSAGE);
            }
            aiCalls = count;
            AiCompletionPort.AiCompletionRequest bound = request.jobId() != null ? request
                    : request.withJobId(job.id());
            // 一次调用可能比租约还长(等名额 + 服务商超时 + 重试一次): 调用期间定时续租, 结束立即再续一次。
            ScheduledFuture<?> heartbeat = keepLeaseDuringCall();
            try {
                return completion.completeJson(bound);
            } finally {
                if (heartbeat != null) {
                    heartbeat.cancel(false);
                }
                touch(null, null);
            }
        }

        @Override
        public boolean aiAllowed() {
            return holdsAiUse() && completion.availability().available();
        }

        private boolean holdsAiUse() {
            return principal.getPermissions() != null && principal.getPermissions().contains(AiPermissions.AI_USE);
        }
    }

    private Map<String, String> parseParams(String json) {
        if (json == null || json.isBlank()) {
            return Map.of();
        }
        try {
            Map<String, String> parsed = objectMapper.readValue(json,
                    new TypeReference<LinkedHashMap<String, String>>() {
                    });
            return parsed == null ? Map.of() : java.util.Collections.unmodifiableMap(parsed);
        } catch (IOException e) {
            return Map.of();
        }
    }
}
