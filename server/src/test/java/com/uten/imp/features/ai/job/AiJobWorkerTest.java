package com.uten.imp.features.ai.job;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiCompletionPort;
import com.uten.imp.application.port.AiCompletionPort.AiCallException;
import com.uten.imp.application.port.AiCompletionPort.AiErrorCategory;
import com.uten.imp.application.port.AiJobHandler;
import com.uten.imp.application.port.BusinessDataResetGatePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.features.ai.gateway.AiGateway;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SubmitterPrincipalRestorer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.SimpleTransactionStatus;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Function;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** 后台处理: 主体重建、终态、取消、排水中止、0 行即停、认领令牌、AI 调用期间续租与 AI 调用次数(ADR-133)。 */
class AiJobWorkerTest {

    /** 这次认领的令牌(attempts); 故意不是 1, 证明每次写入带的是认领返回的值。 */
    private static final int ATTEMPT = 2;
    private static final int LEASE = 600;

    private final UUID jobId = UUID.randomUUID();
    private final UUID userId = UUID.randomUUID();
    private final UUID employeeId = UUID.randomUUID();
    private AiJobRepository repository;
    private SubmitterPrincipalRestorer restorer;
    private AiCompletionPort completion;
    private FakeGate gate;
    private AiProperties properties;
    private AiJobWorker worker;
    private Function<AiJobHandler.AiJobContext, Map<String, Object>> behaviour;

    /** 可切换状态的排水闸。 */
    private static final class FakeGate implements BusinessDataResetGatePort {
        volatile boolean blocking;
        volatile int entered;

        @Override
        public synchronized boolean tryEnter() {
            if (blocking) {
                return false;
            }
            entered++;
            return true;
        }

        @Override
        public synchronized void leave() {
            entered--;
        }

        @Override
        public boolean blockingNewRequests() {
            return blocking;
        }
    }

    private final class ScriptedHandler implements AiJobHandler {
        @Override
        public String kind() {
            return "TEST_KIND";
        }

        @Override
        public void authorizeSubmit(Map<String, String> params) {
        }

        @Override
        public void validateInput(Map<String, String> params, AiJobInput input) {
        }

        @Override
        public long maxInputBytes() {
            return 1024;
        }

        @Override
        public Set<String> acceptedKinds() {
            return Set.of("CSV");
        }

        @Override
        public void authorizeRead(Map<String, String> params) {
        }

        @Override
        public Map<String, Object> filterResultForReader(Map<String, Object> result) {
            return result;
        }

        @Override
        public Map<String, Object> process(AiJobContext ctx) {
            return behaviour.apply(ctx);
        }
    }

    @BeforeEach
    void setUp() {
        repository = mock(AiJobRepository.class);
        restorer = mock(SubmitterPrincipalRestorer.class);
        completion = mock(AiCompletionPort.class);
        gate = new FakeGate();
        properties = new AiProperties();
        PlatformTransactionManager transactions = mock(PlatformTransactionManager.class);
        when(transactions.getTransaction(any())).thenReturn(new SimpleTransactionStatus());
        worker = new AiJobWorker(repository, new AiJobHandlerRegistry(List.of(new ScriptedHandler())), restorer,
                completion, gate, properties, new ObjectMapper(), transactions, Executors.newSingleThreadExecutor());
        when(restorer.restore(userId, 5, 2L)).thenReturn(principal(Set.of("ai:use")));
        when(repository.progress(eq(jobId), eq(ATTEMPT), any(), any(), anyInt())).thenReturn(Optional.of(false));
        when(repository.cancelRequested(jobId, ATTEMPT)).thenReturn(Optional.of(false));
        when(repository.finishSucceeded(eq(jobId), eq(ATTEMPT), anyString())).thenReturn(1);
        when(repository.finishFailed(eq(jobId), eq(ATTEMPT), anyString(), anyString())).thenReturn(1);
        when(completion.availability()).thenReturn(new AiCompletionPort.AiAvailability(true, "p", "m", false, null));
    }

    @AfterEach
    void tearDown() {
        worker.close();
        SecurityContextHolder.clearContext();
    }

    private AuthUser principal(Set<String> permissions) {
        return new AuthUser(userId, employeeId, "13900000009", permissions, false, true, false);
    }

    private AiJobRepository.ClaimedJob claimed(String kind) {
        return new AiJobRepository.ClaimedJob(jobId, kind, "{\"clientId\":\"c1\"}", "list.csv", "text/csv", "CSV",
                5, "a".repeat(64), "hello".getBytes(), userId, employeeId, 5, 2L, ATTEMPT, 0);
    }

    @Test
    void runsWithTheRestoredSubmitterAndStoresTheResult() throws Exception {
        AtomicReference<Object> principalSeen = new AtomicReference<>();
        behaviour = ctx -> {
            principalSeen.set(SecurityContextHolder.getContext().getAuthentication().getPrincipal());
            ctx.progress("READING", 10);
            assertThat(ctx.params()).containsEntry("clientId", "c1");
            assertThat(new String(ctx.input().bytes())).isEqualTo("hello");
            assertThat(ctx.submittedByEmployee()).isEqualTo(employeeId);
            return Map.of("lines", List.of(1, 2));
        };

        worker.process(claimed("TEST_KIND"));

        assertThat(principalSeen.get()).isInstanceOf(AuthUser.class);
        assertThat(((AuthUser) principalSeen.get()).getId()).isEqualTo(userId);
        assertThat(SecurityContextHolder.getContext().getAuthentication()).isNull();
        verify(repository).progress(jobId, ATTEMPT, "READING", 10, LEASE);
        ArgumentCaptor<String> json = ArgumentCaptor.forClass(String.class);
        verify(repository).finishSucceeded(eq(jobId), eq(ATTEMPT), json.capture());
        assertThat(new ObjectMapper().readTree(json.getValue()).path("lines").size()).isEqualTo(2);
        assertThat(gate.entered).isZero();
    }

    @Test
    void changedPrincipalFailsTheJobWithoutRunningTheHandler() {
        when(restorer.restore(userId, 5, 2L))
                .thenThrow(new SubmitterPrincipalRestorer.PrincipalChangedException("authorization_changed"));
        AtomicBoolean ran = new AtomicBoolean();
        behaviour = ctx -> {
            ran.set(true);
            return Map.of();
        };

        worker.process(claimed("TEST_KIND"));

        assertThat(ran).isFalse();
        verify(repository).finishFailed(jobId, ATTEMPT, "PRINCIPAL_CHANGED", "账号权限已变化, 请重新识别");
    }

    @Test
    void databaseTroubleWhileRestoringTheSubmitterFailsTheJobGenerically() {
        when(restorer.restore(userId, 5, 2L))
                .thenThrow(new org.springframework.dao.DataAccessResourceFailureException("connection refused"));
        behaviour = ctx -> Map.of();

        worker.process(claimed("TEST_KIND"));

        verify(repository).finishFailed(jobId, ATTEMPT, "INTERNAL", "识别失败, 请稍后重试");
        verify(repository, never()).finishSucceeded(any(), anyInt(), any());
    }

    @Test
    void handlerApiExceptionsKeepTheirPlainMessageAndOthersBecomeGeneric() {
        behaviour = ctx -> {
            throw new ApiException(ErrorCode.BUSINESS, "文件里没有找到货品明细");
        };
        worker.process(claimed("TEST_KIND"));
        verify(repository).finishFailed(jobId, ATTEMPT, "BUSINESS", "文件里没有找到货品明细");

        behaviour = ctx -> {
            throw new IllegalStateException("customer secret line text");
        };
        worker.process(claimed("TEST_KIND"));
        verify(repository).finishFailed(jobId, ATTEMPT, "INTERNAL", "识别失败, 请稍后重试");
    }

    @Test
    void handlerErrorCodeFieldBecomesTheJobErrorCode() {
        behaviour = ctx -> {
            throw new ApiException(ErrorCode.BUSINESS, "PDF/图片需要开启 AI 才能识别",
                    List.of(new com.uten.imp.common.web.ApiError.FieldError("errorCode", "AI_REQUIRED")));
        };
        worker.process(claimed("TEST_KIND"));
        verify(repository).finishFailed(jobId, ATTEMPT, "AI_REQUIRED", "PDF/图片需要开启 AI 才能识别");

        // 不合格式的业务码(小写、空格、太长)不写进去, 退回错误类别名。
        behaviour = ctx -> {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "文件不对",
                    List.of(new com.uten.imp.common.web.ApiError.FieldError("errorCode", "bad code"),
                            new com.uten.imp.common.web.ApiError.FieldError("qty", "X")));
        };
        worker.process(claimed("TEST_KIND"));
        verify(repository).finishFailed(jobId, ATTEMPT, "VALIDATION_FAILED", "文件不对");

        assertThat(AiJobWorker.errorCodeOf(new ApiException(ErrorCode.BUSINESS, "x",
                List.of(new com.uten.imp.common.web.ApiError.FieldError("errorCode", "A".repeat(49))))))
                .isEqualTo("BUSINESS");
        assertThat(AiJobWorker.errorCodeOf(new ApiException(ErrorCode.BUSINESS, "x",
                List.of(new com.uten.imp.common.web.ApiError.FieldError("errorCode", "AI_VISION_UNAVAILABLE")))))
                .isEqualTo("AI_VISION_UNAVAILABLE");
    }

    @Test
    void aHandlerThatSawTheCancelAndReturnedNothingEndsCancelledNotSucceeded() {
        when(repository.progress(eq(jobId), eq(ATTEMPT), any(), any(), anyInt()))
                .thenReturn(Optional.of(false), Optional.of(true));
        when(repository.finishCancelled(jobId, ATTEMPT)).thenReturn(1);
        behaviour = ctx -> {
            ctx.progress("READING", 10);
            ctx.progress("MATCHING_GOODS", 60);
            if (ctx.cancelled()) {
                return Map.of();
            }
            throw new AssertionError("cancel flag must be visible after progress");
        };

        worker.process(claimed("TEST_KIND"));

        verify(repository).finishCancelled(jobId, ATTEMPT);
        verify(repository, never()).finishSucceeded(any(), anyInt(), any());
        verify(repository, never()).finishFailed(any(), anyInt(), any(), any());
    }

    @Test
    void aiFailuresShowPlainWordsToSalesAndKeepTheCategoryInTheErrorCode() {
        Object[][] cases = {
                {AiErrorCategory.QUOTA, "服务商账户余额不足", "AI_QUOTA", AiJobWorker.AI_BUSY_MESSAGE},
                {AiErrorCategory.RATE_LIMIT, "调用太频繁或额度不足, 请稍后再试", "AI_RATE_LIMIT", AiJobWorker.AI_BUSY_MESSAGE},
                {AiErrorCategory.AUTH, "密钥无效或没有权限(也可能是账号所在区域不匹配)", "AI_AUTH",
                        AiJobWorker.AI_UNAVAILABLE_MESSAGE},
                {AiErrorCategory.BAD_REQUEST, "服务商不接受这个请求: Unsupported model gpt-x", "AI_BAD_REQUEST",
                        AiJobWorker.AI_UNAVAILABLE_MESSAGE},
                {AiErrorCategory.NOT_FOUND, "接口地址或模型名称不对", "AI_NOT_FOUND", AiJobWorker.AI_UNAVAILABLE_MESSAGE},
                {AiErrorCategory.UNAVAILABLE, "还没有配置 AI 服务", "AI_UNAVAILABLE", AiJobWorker.AI_UNAVAILABLE_MESSAGE},
                {AiErrorCategory.BLOCKED, "接口地址指向内网, 已拦截", "AI_BLOCKED", AiJobWorker.AI_UNAVAILABLE_MESSAGE},
                {AiErrorCategory.SERVER, "AI 服务暂时出错(服务商返回 503), 请稍后再试", "AI_SERVER",
                        AiJobWorker.GENERIC_FAILURE_MESSAGE},
                {AiErrorCategory.INVALID_RESPONSE, "AI 输出被截断(超过最大输出长度), 请在 AI 服务设置里调大最大输出长度",
                        "AI_INVALID_RESPONSE", AiJobWorker.GENERIC_FAILURE_MESSAGE},
                {AiErrorCategory.TIMEOUT, "AI 服务响应超时", "AI_TIMEOUT", AiJobWorker.GENERIC_FAILURE_MESSAGE},
                {AiErrorCategory.NETWORK, "连不上 AI 服务", "AI_NETWORK", AiJobWorker.GENERIC_FAILURE_MESSAGE},
                // 平台自己的 BLOCKED 提示本来就是给业务人员看的, 原样保留。
                {AiErrorCategory.BLOCKED, AiGateway.VISION_UNSUPPORTED_MESSAGE, "AI_BLOCKED",
                        AiGateway.VISION_UNSUPPORTED_MESSAGE},
                {AiErrorCategory.BLOCKED, AiJobWorker.CALL_CAP_MESSAGE, "AI_BLOCKED", AiJobWorker.CALL_CAP_MESSAGE},
        };
        for (Object[] c : cases) {
            AiErrorCategory category = (AiErrorCategory) c[0];
            String raw = (String) c[1];
            behaviour = ctx -> {
                throw new AiCallException(category, raw, 503);
            };
            worker.process(claimed("TEST_KIND"));
            verify(repository).finishFailed(jobId, ATTEMPT, (String) c[2], (String) c[3]);
            org.mockito.Mockito.clearInvocations(repository);
        }
        for (AiErrorCategory category : AiErrorCategory.values()) {
            assertThat(AiJobWorker.plainAiFailureMessage(new AiCallException(category, "provider raw text gpt-x")))
                    .as(category.name())
                    .isIn(AiJobWorker.AI_BUSY_MESSAGE, AiJobWorker.AI_UNAVAILABLE_MESSAGE,
                            AiJobWorker.GENERIC_FAILURE_MESSAGE);
        }
    }

    @Test
    void unknownKindsFailImmediately() {
        worker.process(claimed("RETIRED_KIND"));

        verify(repository).finishFailed(eq(jobId), eq(ATTEMPT), eq("UNKNOWN_KIND"), anyString());
        verify(restorer, never()).restore(any(), org.mockito.ArgumentMatchers.anyLong(), any());
    }

    @Test
    void cancellationSeenThroughProgressEndsAsCancelled() {
        when(repository.progress(eq(jobId), eq(ATTEMPT), any(), any(), anyInt())).thenReturn(Optional.of(true));
        when(repository.finishCancelled(jobId, ATTEMPT)).thenReturn(1);
        behaviour = ctx -> {
            ctx.progress("MATCHING", 50);
            assertThat(ctx.cancelled()).isTrue();
            return Map.of("partial", true);
        };

        worker.process(claimed("TEST_KIND"));

        verify(repository).finishCancelled(jobId, ATTEMPT);
        verify(repository, never()).finishSucceeded(any(), anyInt(), any());
    }

    @Test
    void vanishedRowsStopQuietly() {
        when(repository.progress(eq(jobId), eq(ATTEMPT), any(), any(), anyInt())).thenReturn(Optional.empty());
        behaviour = ctx -> {
            ctx.progress("READING", 5);
            assertThat(ctx.cancelled()).isTrue();
            return Map.of();
        };

        worker.process(claimed("TEST_KIND"));

        verifyNoTerminalWrite();
    }

    private void verifyNoTerminalWrite() {
        verify(repository, never()).finishSucceeded(any(), anyInt(), any());
        verify(repository, never()).finishFailed(any(), anyInt(), any(), any());
        verify(repository, never()).finishCancelled(any(), anyInt());
        verify(repository, never()).releaseForShutdown(any(), anyInt());
    }

    @Test
    void theLeaseIsRenewedWhileAnAiCallOutlivesItAndTheRenewalStopsAfterTheCall() throws Exception {
        properties.setJobLeaseSeconds(1);   // 续租间隔 250 ms
        when(repository.incrementAiCalls(jobId, ATTEMPT, 12, 1)).thenReturn(1);
        when(completion.completeJson(any())).thenAnswer(invocation -> {
            Thread.sleep(1_300);            // 比租约还长的一次 AI 调用
            return new AiCompletionPort.AiCompletionResult("{}", "p", "m", 1, 1, 1_300);
        });
        behaviour = ctx -> {
            ctx.completeJson(new AiCompletionPort.AiCompletionRequest("P", "sys",
                    List.of(new AiCompletionPort.AiText("x", true)), null, null, 100, null));
            return Map.of("ok", true);
        };

        worker.process(claimed("TEST_KIND"));

        // 调用期间至少续租 3 次(250/500/750/1000 ms), 再加调用结束后的一次。
        verify(repository, org.mockito.Mockito.atLeast(4)).progress(jobId, ATTEMPT, null, null, 1);
        verify(repository).finishSucceeded(eq(jobId), eq(ATTEMPT), anyString());
        Thread.sleep(100);
        int renewals = org.mockito.Mockito.mockingDetails(repository).getInvocations().stream()
                .filter(invocation -> invocation.getMethod().getName().equals("progress")).toList().size();
        Thread.sleep(700);
        int later = org.mockito.Mockito.mockingDetails(repository).getInvocations().stream()
                .filter(invocation -> invocation.getMethod().getName().equals("progress")).toList().size();
        assertThat(later).as("renewal stops when the call returns").isEqualTo(renewals);
    }

    @Test
    void aWorkerWhoseClaimWasTakenOverStopsWithoutAnyTerminalWrite() {
        properties.setJobLeaseSeconds(1);
        when(repository.incrementAiCalls(jobId, ATTEMPT, 12, 1)).thenReturn(1);
        // 调用期间租约过期、任务被重新认领(attempts 已变): 带旧令牌的续租影响 0 行。
        when(repository.progress(eq(jobId), eq(ATTEMPT), any(), any(), anyInt())).thenReturn(Optional.empty());
        when(completion.completeJson(any())).thenAnswer(invocation -> {
            Thread.sleep(600);
            return new AiCompletionPort.AiCompletionResult("{}", "p", "m", 1, 1, 600);
        });
        AtomicBoolean sawCancelled = new AtomicBoolean();
        behaviour = ctx -> {
            ctx.completeJson(new AiCompletionPort.AiCompletionRequest("P", "sys",
                    List.of(new AiCompletionPort.AiText("x", true)), null, null, 100, null));
            sawCancelled.set(ctx.cancelled());
            assertThatThrownBy(() -> ctx.completeJson(new AiCompletionPort.AiCompletionRequest("P", "sys",
                    List.of(new AiCompletionPort.AiText("x", true)), null, null, 100, null)))
                    .isInstanceOf(AiCallException.class);
            return Map.of("ok", true);
        };

        worker.process(claimed("TEST_KIND"));

        assertThat(sawCancelled).isTrue();
        verify(completion, org.mockito.Mockito.times(1)).completeJson(any());
        verify(repository, org.mockito.Mockito.times(1)).incrementAiCalls(any(), anyInt(), anyInt(), anyInt());
        verifyNoTerminalWrite();
    }

    @Test
    void businessDataResetDrainAbortsBetweenStages() {
        behaviour = ctx -> {
            gate.blocking = true;
            ctx.progress("MATCHING", 40);
            assertThat(ctx.cancelled()).isTrue();
            gate.blocking = false;
            return Map.of();
        };

        worker.process(claimed("TEST_KIND"));

        verify(repository).finishFailed(jobId, ATTEMPT, "RESETTING", "系统正在重置数据, 请稍后重试");
        verify(repository, never()).finishSucceeded(any(), anyInt(), any());
    }

    @Test
    void aiCallsNeedAiUseAreCappedAndCarryTheJobId() {
        when(repository.incrementAiCalls(jobId, ATTEMPT, 12, LEASE)).thenReturn(1, -2);
        AiCompletionPort.AiCompletionResult reply = new AiCompletionPort.AiCompletionResult("{}", "p", "m", 1, 1, 5);
        when(completion.completeJson(any())).thenReturn(reply);
        AtomicReference<AiCallException> exhausted = new AtomicReference<>();
        behaviour = ctx -> {
            assertThat(ctx.aiAllowed()).isTrue();
            assertThat(ctx.remainingAiCalls()).isEqualTo(12);
            ctx.completeJson(new AiCompletionPort.AiCompletionRequest("P", "sys",
                    List.of(new AiCompletionPort.AiText("x", true)), null, null, 100, null));
            assertThat(ctx.remainingAiCalls()).isEqualTo(11);
            try {
                ctx.completeJson(new AiCompletionPort.AiCompletionRequest("P", "sys",
                        List.of(new AiCompletionPort.AiText("x", true)), null, null, 100, null));
            } catch (AiCallException e) {
                exhausted.set(e);
            }
            return Map.of();
        };

        worker.process(claimed("TEST_KIND"));

        ArgumentCaptor<AiCompletionPort.AiCompletionRequest> sent =
                ArgumentCaptor.forClass(AiCompletionPort.AiCompletionRequest.class);
        verify(completion).completeJson(sent.capture());
        assertThat(sent.getValue().jobId()).isEqualTo(jobId);
        assertThat(exhausted.get().category()).isEqualTo(AiErrorCategory.BLOCKED);
        assertThat(exhausted.get().getMessage()).contains("次数已达上限");
        verify(repository).finishSucceeded(eq(jobId), eq(ATTEMPT), anyString());
    }

    @Test
    void withoutAiUseTheHandlerRunsRulesOnly() {
        when(restorer.restore(userId, 5, 2L)).thenReturn(principal(Set.of("sales_quote:create")));
        behaviour = ctx -> {
            assertThat(ctx.aiAllowed()).isFalse();
            assertThatThrownBy(() -> ctx.completeJson(new AiCompletionPort.AiCompletionRequest("P", "sys",
                    List.of(new AiCompletionPort.AiText("x", true)), null, null, 100, null)))
                    .isInstanceOf(AiCallException.class)
                    .extracting(error -> ((AiCallException) error).category()).isEqualTo(AiErrorCategory.BLOCKED);
            return Map.of("rulesOnly", true);
        };

        worker.process(claimed("TEST_KIND"));

        verify(completion, never()).completeJson(any());
        verify(repository, never()).incrementAiCalls(any(), anyInt(), anyInt(), anyInt());
        verify(repository).finishSucceeded(eq(jobId), eq(ATTEMPT), anyString());
    }

    @Test
    void claimsNothingWhileTheResetGateIsClosed() {
        gate.blocking = true;

        assertThat(worker.processNext()).isFalse();
        verify(repository, never()).claimNext(anyInt());
    }

    @Test
    void wakeDrainsClaimedJobsOnTheDedicatedExecutor() throws Exception {
        when(repository.claimNext(LEASE)).thenReturn(Optional.of(claimed("TEST_KIND")), Optional.empty());
        behaviour = ctx -> Map.of("done", true);

        worker.wake();

        long deadline = System.currentTimeMillis() + 5_000;
        while (System.currentTimeMillis() < deadline) {
            try {
                verify(repository).finishSucceeded(eq(jobId), eq(ATTEMPT), anyString());
                break;
            } catch (AssertionError notYet) {
                Thread.sleep(20);
            }
        }
        verify(repository).finishSucceeded(eq(jobId), eq(ATTEMPT), anyString());
    }

    @Test
    void logsNeverCarryHandlerExceptionMessages() {
        Throwable redacted = AiJobWorker.redacted(new IllegalStateException("客户邮箱 buyer@example.com",
                new RuntimeException("SWIFT ICBKCNBJ")));

        assertThat(redacted.getMessage()).isEqualTo("java.lang.IllegalStateException");
        assertThat(redacted.getCause().getMessage()).isEqualTo("caused by java.lang.RuntimeException");
        assertThat(redacted.getStackTrace()).isNotEmpty();
    }
}
