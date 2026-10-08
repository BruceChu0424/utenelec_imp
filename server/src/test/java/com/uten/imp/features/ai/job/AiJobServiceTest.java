package com.uten.imp.features.ai.job;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiJobHandler;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.features.ai.usage.AiUserLimitsService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SubmitterPrincipalRestorer;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.SimpleTransactionStatus;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

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

/** 提交顺序、限额、幂等、只给本人看与读取时重新授权/过滤(ADR-133)。 */
class AiJobServiceTest {

    @Test void acceptedQuestionIsBoundToTheRealSubmitterAndRecordedWithoutDocumentBytes() throws Exception {
        var result = submit(Map.of("message", "生成报价 api_key=private-secret"), new ByteArrayInputStream(CSV));
        verify(repository).recordAuditQuestion(eq(result.id()), eq(user.getId()), eq("生成报价 api_key=[已隐藏]"), eq("REDACTED"));
    }

    private static final byte[] CSV = "model,qty\nGZ23,10\n".getBytes(StandardCharsets.UTF_8);

    private final List<String> calls = new ArrayList<>();
    private final Map<UUID, com.uten.imp.features.ai.usage.AiUserLimitsService.Limits> limitsRows = new HashMap<>();
    private AiJobRepository repository;
    private SubmitterPrincipalRestorer restorer;
    private ApplicationEventPublisher events;
    private AiProperties properties;
    private AiJobService service;
    private AuthUser user;
    private RecordingHandler handler;

    /** 记录调用顺序的处理器。 */
    private final class RecordingHandler implements AiJobHandler {
        Map<String, Object> filtered = Map.of("filtered", true);
        boolean denyRead;
        boolean acceptsJson;
        boolean denyResult;

        @Override
        public String kind() {
            return "TEST_KIND";
        }

        @Override
        public void authorizeSubmit(Map<String, String> params) {
            calls.add("authorizeSubmit");
            if ("deny".equals(params.get("mode"))) {
                throw new ApiException(ErrorCode.FORBIDDEN, "没有权限识别这类文件");
            }
        }

        @Override
        public void validateInput(Map<String, String> params, AiJobInput input) {
            calls.add("validateInput:" + input.kind() + ":" + input.size());
        }

        @Override
        public long maxInputBytes() {
            return 1024;
        }

        @Override
        public Set<String> acceptedKinds() {
            return acceptsJson ? Set.of("JSON") : Set.of("CSV", "XLSX");
        }

        @Override
        public void authorizeRead(Map<String, String> params) {
            calls.add("authorizeRead");
            if (denyRead) {
                throw new ApiException(ErrorCode.FORBIDDEN, "已没有查看权限");
            }
        }

        @Override
        public Map<String, Object> filterResultForReader(Map<String, Object> result) {
            if (denyResult) throw new ApiException(ErrorCode.FORBIDDEN);
            calls.add("filter:" + result.keySet());
            return filtered;
        }

        @Override
        public Map<String, Object> process(AiJobContext ctx) {
            return Map.of();
        }
    }

    /** 读一个字节就记下「读了请求体」。 */
    private final class TrackingStream extends InputStream {
        private final ByteArrayInputStream delegate;

        TrackingStream(byte[] bytes) {
            this.delegate = new ByteArrayInputStream(bytes);
        }

        @Override
        public int read() {
            calls.add("readBody");
            return delegate.read();
        }

        @Override
        public int read(byte[] buffer, int offset, int length) {
            if (!calls.contains("readBody")) {
                calls.add("readBody");
            }
            return delegate.read(buffer, offset, length);
        }
    }

    @BeforeEach
    void setUp() {
        calls.clear();
        limitsRows.clear();
        repository = mock(AiJobRepository.class);
        restorer = mock(SubmitterPrincipalRestorer.class);
        events = mock(ApplicationEventPublisher.class);
        properties = new AiProperties();
        handler = new RecordingHandler();
        PlatformTransactionManager transactions = mock(PlatformTransactionManager.class);
        when(transactions.getTransaction(any())).thenReturn(new SimpleTransactionStatus());
        // ADR-164 limits gate uses the real AiUserLimitsService (a fake on a mocked JdbcTemplate):
        // the paused/personal-quota behaviour then asserts real messages, not stubbed ones.
        NamedParameterJdbcTemplate limitsJdbc = mock(NamedParameterJdbcTemplate.class);
        when(limitsJdbc.query(anyString(), any(MapSqlParameterSource.class),
                org.mockito.ArgumentMatchers.<RowMapper<AiUserLimitsService.Limits>>any()))
                .thenAnswer(invocation -> {
                    UUID limited = (UUID) ((MapSqlParameterSource) invocation.getArgument(1)).getValue("userId");
                    var row = limitsRows.get(limited);
                    return row == null ? List.of() : List.of(row);
                });
        service = new AiJobService(new AiJobHandlerRegistry(List.of(handler)), repository, restorer, properties,
                events, new ObjectMapper(), transactions,mock(AiInputOriginalStore.class),
                new com.uten.imp.features.ai.usage.AiUserLimitsService(limitsJdbc, mock(AuditService.class)));
        user = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "13900000001", Set.of("ai:use"), false, true,
                false);
        when(restorer.currentStamps(user.getId()))
                .thenReturn(Optional.of(new SubmitterPrincipalRestorer.AuthorizationStamps(5, 2)));
        when(repository.findReusable(any(), anyString(), anyString(), anyString(), anyString(), anyInt()))
                .thenReturn(Optional.empty());
        when(repository.findOwned(any(), eq(user.getId()))).thenAnswer(invocation -> Optional.of(row(
                invocation.getArgument(0), "PENDING", false)));
    }

    private AiJobRepository.JobRow row(UUID id, String status, boolean hasResult) {
        return new AiJobRepository.JobRow(id, "TEST_KIND", status, null, 0, false, "{\"clientId\":\"c1\"}",
                "list.csv", "CSV", CSV.length, user.getId(), OffsetDateTime.now(), null, null, null, null, null, null,
                hasResult);
    }

    private AiJobView submit(Map<String, String> params, InputStream body) throws Exception {
        return service.submit("TEST_KIND", params, "list.csv", "text/csv", body, -1, user);
    }

    @Test
    void authorizesBeforeReadingTheBodyThenSniffsValidatesAndEnqueuesWithTheSubmitterStamps() throws Exception {
        AiJobView view = submit(new LinkedHashMap<>(Map.of("clientId", "c1")), new TrackingStream(CSV));

        assertThat(calls).startsWith("authorizeSubmit", "readBody");
        assertThat(calls).contains("validateInput:CSV:" + CSV.length);
        ArgumentCaptor<AiJobRepository.NewJob> inserted = ArgumentCaptor.forClass(AiJobRepository.NewJob.class);
        verify(repository).lockSubmitter(user.getId());
        verify(repository).insert(inserted.capture());
        AiJobRepository.NewJob job = inserted.getValue();
        assertThat(job.kind()).isEqualTo("TEST_KIND");
        assertThat(job.paramsJson()).isEqualTo("{\"clientId\":\"c1\"}");
        assertThat(job.inputKind()).isEqualTo("CSV");
        assertThat(job.inputSha256()).isEqualTo(AiJobService.sha256(CSV)).hasSize(64);
        assertThat(job.submittedAuthVersion()).isEqualTo(5);
        assertThat(job.submittedAuthEpoch()).isEqualTo(2);
        assertThat(job.submittedByEmployee()).isEqualTo(user.getEmployeeId());
        verify(events).publishEvent(new AiJobSubmittedEvent(job.id()));
        assertThat(view.jobId()).isEqualTo(job.id());
        assertThat(view.status()).isEqualTo("PENDING");
    }

    @Test
    void refusedSubmissionNeverReadsTheBody() {
        assertThatThrownBy(() -> submit(Map.of("mode", "deny"), new TrackingStream(CSV)))
                .isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.FORBIDDEN);
        assertThat(calls).containsExactly("authorizeSubmit");
        verify(repository, never()).insert(any());
    }

    @Test
    void perUserAndGlobalLimitsRejectBeforeReadingTheBody() {
        when(repository.countActive(user.getId())).thenReturn(2);
        assertThatThrownBy(() -> submit(Map.of(), new TrackingStream(CSV)))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> {
                    assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.RATE_LIMITED);
                    assertThat(error.getMessage()).isEqualTo("你已有识别任务在进行, 请稍等");
                });
        assertThat(calls).doesNotContain("readBody");

        when(repository.countActive(user.getId())).thenReturn(0);
        when(repository.countToday(user.getId())).thenReturn(60);
        assertThatThrownBy(() -> submit(Map.of(), new TrackingStream(CSV)))
                .isInstanceOf(ApiException.class).hasMessageContaining("今天");

        when(repository.countToday(user.getId())).thenReturn(0);
        when(repository.countPending()).thenReturn(100);
        assertThatThrownBy(() -> submit(Map.of(), new TrackingStream(CSV)))
                .isInstanceOf(ApiException.class).hasMessageContaining("排队");
        assertThat(calls).doesNotContain("readBody");
    }

    @Test
    void rejectsVisitorsUnboundAccountsUnknownKindsAndBadParameters() {
        AuthUser visitor = AuthUser.visitor(UUID.randomUUID(), "V001", "V001", Set.of());
        assertThatThrownBy(() -> service.submit("TEST_KIND", Map.of(), "a.csv", null, new ByteArrayInputStream(CSV),
                -1, visitor)).isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.FORBIDDEN);
        AuthUser unbound = new AuthUser(UUID.randomUUID(), null, "x", Set.of(), false, true, false);
        assertThatThrownBy(() -> service.submit("TEST_KIND", Map.of(), "a.csv", null, new ByteArrayInputStream(CSV),
                -1, unbound)).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> service.submit("NOPE", Map.of(), "a.csv", null, new ByteArrayInputStream(CSV), -1,
                user)).isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.NOT_FOUND);
        assertThatThrownBy(() -> submit(Map.of("bad key", "x"), new ByteArrayInputStream(CSV)))
                .isInstanceOf(ApiException.class).hasMessage("识别的附加设置不正确");
        assertThatThrownBy(() -> submit(Map.of("note", "line\nbreak"), new ByteArrayInputStream(CSV)))
                .isInstanceOf(ApiException.class).hasMessage("识别的附加设置不正确");
    }

    @Test
    void oversizedAndUnsupportedFilesAreRejectedBeforeValidation() {
        assertThatThrownBy(() -> submit(Map.of(), new ByteArrayInputStream(new byte[2048])))
                .isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.PAYLOAD_TOO_LARGE);
        assertThatThrownBy(() -> service.submit("TEST_KIND", Map.of(), "photo.png", "image/png",
                new ByteArrayInputStream(new byte[]{(byte) 0x89, 'P', 'N', 'G', 13, 10, 26, 10}), -1, user))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> {
                    assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.UNSUPPORTED_MEDIA_TYPE);
                    assertThat(error.getMessage()).contains("CSV").contains("Excel(xlsx)");
                });
        assertThat(calls).noneMatch(call -> call.startsWith("validateInput"));
    }

    @Test
    void sameFileSameParametersWithinTheWindowReusesTheExistingJob() throws Exception {
        UUID existing = UUID.randomUUID();
        when(repository.findReusable(eq(user.getId()), eq("TEST_KIND"), eq("{\"clientId\":\"c1\"}"),
                eq(AiJobService.sha256(CSV)), eq("list.csv"), eq(10))).thenReturn(Optional.of(existing));

        AiJobView view = submit(Map.of("clientId", "c1"), new ByteArrayInputStream(CSV));

        assertThat(view.id()).isEqualTo(existing);
        verify(repository, never()).insert(any());
        verify(events, never()).publishEvent(any());
    }

    @Test
    void repeatedStructuredQuestionCreatesFreshJobsInsteadOfReusingStaleBusinessFacts() {
        handler.acceptsJson = true;
        byte[] question = "{\"message\":\"我的工作台\"}".getBytes(StandardCharsets.UTF_8);
        AiJobView first = service.submitStructured("TEST_KIND", Map.of(), question, user);
        AiJobView second = service.submitStructured("TEST_KIND", Map.of(), question, user);
        assertThat(second.id()).isNotEqualTo(first.id());
        verify(repository, never()).findReusable(any(), anyString(), anyString(), anyString(), anyString(), anyInt());
    }

    @Test
    void sameFileCanBeRecognizedAgainWhenStoredCandidateScopeWasRevoked() throws Exception {
        UUID stale = UUID.randomUUID();
        when(repository.findReusable(any(), anyString(), anyString(), anyString(), anyString(), anyInt())).thenReturn(Optional.of(stale));
        when(repository.findOwned(stale, user.getId())).thenReturn(Optional.of(row(stale, "SUCCEEDED", true)));
        when(repository.resultJson(stale)).thenReturn(Optional.of("{\"client\":{\"name\":\"old\"}}"));
        handler.denyResult = true;
        AiJobView fresh = submit(Map.of(), new ByteArrayInputStream(CSV));
        assertThat(fresh.id()).isNotEqualTo(stale);
        assertThat(fresh.status()).isEqualTo("PENDING");
        verify(repository).insert(any());
    }

    @Test
    void onlyTheSubmitterSeesAJobAndEveryReadReauthorizesAndFilters() {
        UUID id = UUID.randomUUID();
        when(repository.findOwned(id, user.getId())).thenReturn(Optional.of(row(id, "SUCCEEDED", true)));
        when(repository.resultJson(id)).thenReturn(Optional.of("{\"lines\":[1],\"listPrice\":9.9}"));

        AiJobView view = service.view(id, user);

        assertThat(view.result()).isEqualTo(Map.of("filtered", true));
        assertThat(calls).containsExactly("authorizeRead", "filter:[lines, listPrice]");

        AuthUser other = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "13900000002", Set.of(), false, true,
                false);
        when(repository.findOwned(id, other.getId())).thenReturn(Optional.empty());
        assertThatThrownBy(() -> service.view(id, other)).isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.NOT_FOUND);
        assertThatThrownBy(() -> service.cancel(id, other)).isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.NOT_FOUND);

        handler.denyRead = true;
        assertThatThrownBy(() -> service.view(id, user)).isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.FORBIDDEN);
    }

    @Test
    void usedOrPurgedResultsAreNoLongerReturned() {
        UUID id = UUID.randomUUID();
        AiJobRepository.JobRow used = new AiJobRepository.JobRow(id, "TEST_KIND", "SUCCEEDED", "DONE", 100, false,
                "{}", "list.csv", "CSV", 1, user.getId(), OffsetDateTime.now(), null, null, null, null,
                OffsetDateTime.now(), null, true);
        when(repository.findOwned(id, user.getId())).thenReturn(Optional.of(used));

        assertThat(service.view(id, user).result()).isNull();
        verify(repository, never()).resultJson(id);
    }

    @Test
    void cancelStopsPendingJobsAndFlagsRunningOnes() {
        UUID pending = UUID.randomUUID();
        when(repository.findOwned(pending, user.getId())).thenReturn(Optional.of(row(pending, "PENDING", false)));
        when(repository.cancelPending(pending, user.getId())).thenReturn(1);
        service.cancel(pending, user);
        verify(repository).cancelPending(pending, user.getId());
        verify(repository, never()).requestCancel(pending, user.getId());

        UUID running = UUID.randomUUID();
        when(repository.findOwned(running, user.getId())).thenReturn(Optional.of(row(running, "RUNNING", false)));
        service.cancel(running, user);
        verify(repository).requestCancel(running, user.getId());
    }

    // ------------------------------------------------------- ADR-164 按人限额与停用

    @Test
    void anAccountPausedByAnAdminCannotSubmitFileOrStructuredJobs() {
        limitsRows.put(user.getId(),
                new com.uten.imp.features.ai.usage.AiUserLimitsService.Limits(user.getId(), true, null, null, 0));

        assertThatThrownBy(() -> submit(Map.of(), new TrackingStream(CSV)))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> {
                    assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.FORBIDDEN);
                    assertThat(error.getMessage()).contains("已暂停");
                });
        assertThat(calls).containsExactly("authorizeSubmit").doesNotContain("readBody");
        verify(repository, never()).insert(any());

        handler.acceptsJson = true;
        assertThatThrownBy(() -> service.submitStructured("TEST_KIND", Map.of(),
                "{\"message\":\"我的工作台\"}".getBytes(StandardCharsets.UTF_8), user))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> {
                    assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.FORBIDDEN);
                    assertThat(error.getMessage()).contains("已暂停");
                });
        verify(repository, never()).insert(any());
        verify(events, never()).publishEvent(any());
    }

    @Test
    void anEnabledLimitsRowStillSubmitsNormally() throws Exception {
        limitsRows.put(user.getId(),
                new com.uten.imp.features.ai.usage.AiUserLimitsService.Limits(user.getId(), false, 500_000L, null, 3));

        AiJobView view = submit(Map.of(), new ByteArrayInputStream(CSV));

        assertThat(view.status()).isEqualTo("PENDING");
        verify(repository).insert(any());
        verify(events).publishEvent(any(AiJobSubmittedEvent.class));
    }

    @Test
    void aPersonalDailyJobOverrideRejectsTheSixthSubmissionOfTheDay() throws Exception {
        limitsRows.put(user.getId(),
                new com.uten.imp.features.ai.usage.AiUserLimitsService.Limits(user.getId(), false, null, 5, 0));

        when(repository.countToday(user.getId())).thenReturn(5);
        assertThatThrownBy(() -> submit(Map.of(), new ByteArrayInputStream(CSV)))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> {
                    assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.RATE_LIMITED);
                    assertThat(error.getMessage()).contains("今天的识别次数已用完");
                });
        verify(repository, never()).insert(any());

        // 5 个之内(第 5 次提交时 countToday=4)仍可入队。
        when(repository.countToday(user.getId())).thenReturn(4);
        assertThat(submit(Map.of(), new ByteArrayInputStream(CSV)).status()).isEqualTo("PENDING");
    }

    @Test
    void withoutAPersonalOverrideTheGlobalDailyJobCapApplies() throws Exception {
        properties.setMaxJobsPerUserPerDay(3);

        when(repository.countToday(user.getId())).thenReturn(3);
        assertThatThrownBy(() -> submit(Map.of(), new ByteArrayInputStream(CSV)))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> {
                    assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.RATE_LIMITED);
                    assertThat(error.getMessage()).contains("今天的识别次数已用完");
                });

        when(repository.countToday(user.getId())).thenReturn(2);
        assertThat(submit(Map.of(), new ByteArrayInputStream(CSV)).status()).isEqualTo("PENDING");
    }
}
