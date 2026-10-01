package com.uten.imp.features.ai.job;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.port.AiJobUsagePort;
import com.uten.imp.features.ai.AiPlatformPostgresTestSupport;
import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.features.ai.support.FakeAiProviderServer;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/**
 * AI 识别任务队列的真库测试(ADR-133): 上传 → 后台线程以提交人身份处理 → 只给本人看; 每人限额与幂等;
 * 取消; 权限变化即失败; 租约回收与坏文件规则; AI 调用比租约长时续租; 认领令牌; SKIP LOCKED 认领;
 * 终态清空上传文件; 清理任务; 结果使用出口(一个结果只给一张单据)。
 */
class AiJobQueuePostgresTest extends AiPlatformPostgresTestSupport {

    @Autowired
    private AiJobRepository repository;
    @Autowired
    private AiJobHousekeeping housekeeping;
    @Autowired
    private AiJobWorker worker;
    @Autowired
    private AiJobUsagePort usage;
    @Autowired
    private PlatformTransactionManager transactionManager;
    @Autowired
    private AiProperties properties;

    private static byte[] csv(String marker) {
        return ("client,SUNAS " + marker + "\nmodel,qty\nGZ23/D,10\n").getBytes(StandardCharsets.UTF_8);
    }

    private MvcResult submitRaw(String token, Map<String, String> params, byte[] content, String fileName)
            throws Exception {
        var request = post("/api/ai/jobs")
                .param("kind", KIND)
                .contentType(MediaType.APPLICATION_OCTET_STREAM)
                .content(content)
                .header("X-Uten-File-Name", URLEncoder.encode(fileName, StandardCharsets.UTF_8).replace("+", "%20"))
                .header("X-Uten-File-Type", "text/csv")
                .header("Authorization", "Bearer " + token);
        params.forEach(request::param);
        return mvc.perform(request).andReturn();
    }

    private String submit(String token, Map<String, String> params, byte[] content) throws Exception {
        MvcResult result = submitRaw(token, params, content, "客户报价 1.csv");
        assertEquals(202, result.getResponse().getStatus(), body(result));
        return json(result).path("jobId").asText();
    }

    private JsonNode awaitStatus(String token, String jobId, String... terminal) throws Exception {
        long deadline = System.nanoTime() + Duration.ofSeconds(30).toNanos();
        JsonNode view = null;
        while (System.nanoTime() < deadline) {
            view = getJson("/api/ai/jobs/" + jobId, token);
            for (String status : terminal) {
                if (status.equals(view.path("status").asText())) {
                    return view;
                }
            }
            Thread.sleep(100);
        }
        throw new AssertionError("job " + jobId + " did not reach " + String.join("/", terminal) + ": " + view);
    }

    private boolean inputReleased(String jobId) {
        Boolean released = jdbc.queryForObject("SELECT input_bytes IS NULL FROM ai_jobs WHERE id = ?::uuid",
                Boolean.class, jobId);
        return Boolean.TRUE.equals(released);
    }

    private void awaitNoActiveJobs() throws InterruptedException {
        long deadline = System.nanoTime() + Duration.ofSeconds(30).toNanos();
        while (System.nanoTime() < deadline) {
            Integer active = jdbc.queryForObject(
                    "SELECT count(*) FROM ai_jobs WHERE status IN ('PENDING', 'RUNNING')", Integer.class);
            if (active != null && active == 0) {
                return;
            }
            Thread.sleep(100);
        }
        throw new AssertionError("AI jobs still active");
    }

    @Test
    void submitterGetsTheResultProcessedUnderTheirOwnIdentityAndNobodyElseSeesIt() throws Exception {
        Staff owner = aiUser();
        Staff other = aiUser();
        resetToFakeDefaultProvider(adminToken());
        FAKE.enqueue(FakeAiProviderServer.openAiContent("{\"clientName\": \"SUNAS\"}"));

        String jobId = submit(owner.token(), Map.of("mode", "echo", "ai", "1"), csv("owner"));
        JsonNode done = awaitStatus(owner.token(), jobId, "SUCCEEDED", "FAILED");

        assertThat(done.path("status").asText()).as(done.toString()).isEqualTo("SUCCEEDED");
        JsonNode result = done.path("result");
        assertThat(result.path("principal").asText()).isEqualTo(owner.userId());
        assertThat(result.path("employee").asText()).isEqualTo(owner.employeeId());
        assertThat(result.path("fileName").asText()).isEqualTo("客户报价 1.csv");
        assertThat(result.path("kind").asText()).isEqualTo("CSV");
        assertThat(result.path("aiAllowed").asBoolean()).isTrue();
        assertThat(result.path("ai").path("clientName").asText()).isEqualTo("SUNAS");
        assertThat(result.has("secretField")).as("filterResultForReader applied on read").isFalse();
        assertThat(inputReleased(jobId)).isTrue();

        String sent = FAKE.lastChatRequest().body();
        assertThat(sent).contains("UNTRUSTED_DOCUMENT").contains("SUNAS owner");
        Map<String, Object> log = jdbc.queryForMap(
                "SELECT purpose, ok, job_id::text AS job_id, user_id::text AS user_id FROM ai_call_logs "
                        + "WHERE job_id = ?::uuid", jobId);
        assertThat(log).containsEntry("purpose", "PLATFORM_TEST").containsEntry("ok", true)
                .containsEntry("user_id", owner.userId());
        Integer calls = jdbc.queryForObject("SELECT ai_calls FROM ai_jobs WHERE id = ?::uuid", Integer.class, jobId);
        assertThat(calls).isEqualTo(1);

        MvcResult foreign = mvc.perform(authed(get("/api/ai/jobs/" + jobId), other.token())).andReturn();
        assertEquals(404, foreign.getResponse().getStatus(), body(foreign));
        MvcResult foreignCancel = mvc.perform(authed(post("/api/ai/jobs/" + jobId + "/cancel"), other.token()))
                .andReturn();
        assertEquals(404, foreignCancel.getResponse().getStatus(), body(foreignCancel));

        // 同一文件同一参数 10 分钟内重复提交直接复用。
        assertThat(submit(owner.token(), Map.of("mode", "echo", "ai", "1"), csv("owner"))).isEqualTo(jobId);

        // 结果使用出口: 只有本人能读; 先读后标记; 标记即清空, 一个结果只给第一张单据。
        UUID id = UUID.fromString(jobId);
        UUID ownerId = UUID.fromString(owner.userId());
        assertThat(usage.resultFor(id, UUID.fromString(other.userId()))).isEmpty();
        Optional<Map<String, Object>> internal = usage.resultFor(id, ownerId);
        assertThat(internal).isPresent();
        assertThat(internal.get()).containsKey("secretField");
        UUID quoteId = UUID.randomUUID();
        new TransactionTemplate(transactionManager).executeWithoutResult(status ->
                usage.markUsed(id, UUID.fromString(other.userId()), "quote", UUID.randomUUID()));
        assertThat(usage.resultFor(id, ownerId)).as("someone else's markUsed is ignored").isPresent();
        new TransactionTemplate(transactionManager).executeWithoutResult(status ->
                usage.markUsed(id, ownerId, "quote", quoteId));
        assertThat(getJson("/api/ai/jobs/" + jobId, owner.token()).path("result").isNull()).isTrue();
        assertThat(usage.resultFor(id, ownerId)).isEmpty();
        assertThat(jdbc.queryForObject("SELECT result IS NOT NULL AND result_purged_at IS NULL FROM ai_jobs "
                + "WHERE id = ?::uuid", Boolean.class, jobId)).isTrue();
        // 第二张单据既读不到, 也改写不了去向; 同一张单据重放无害。
        UUID orderId = UUID.randomUUID();
        Integer secondDoc = new TransactionTemplate(transactionManager).execute(status ->
                repository.markUsed(id, ownerId, "order", orderId));
        assertThat(secondDoc).isZero();
        Integer replay = new TransactionTemplate(transactionManager).execute(status ->
                repository.markUsed(id, ownerId, "quote", quoteId));
        assertThat(replay).isOne();
        assertThat(jdbc.queryForObject("SELECT used_doc_type || ':' || used_doc_id FROM ai_jobs WHERE id = ?::uuid",
                String.class, jobId)).isEqualTo("quote:" + quoteId);
        // 已被采用的任务不再被复用: 同一文件再次提交是新任务。
        FAKE.enqueue(FakeAiProviderServer.openAiContent("{\"clientName\": \"SUNAS\"}"));
        String again = submit(owner.token(), Map.of("mode", "echo", "ai", "1"), csv("owner"));
        assertThat(again).isNotEqualTo(jobId);
        awaitStatus(owner.token(), again, "SUCCEEDED", "FAILED");
    }

    @Test
    void aLongAiCallKeepsItsLeaseAndTheJobFinishesExactlyOnce() throws Exception {
        Staff owner = aiUser();
        resetToFakeDefaultProvider(adminToken());
        awaitNoActiveJobs();
        int originalLease = properties.getJobLeaseSeconds();
        properties.setJobLeaseSeconds(2);   // 调用期间每 500 ms 续租
        try {
            FAKE.enqueue(FakeAiProviderServer.openAiContent("{\"clientName\": \"SUNAS\"}").withDelay(5_000));
            String jobId = submit(owner.token(), Map.of("mode", "echo", "ai", "1"), csv("long-call"));

            // 调用期间反复回收过期租约: 没有续租的话, 2 秒后任务会被重新排队并由另一个线程再跑一遍。
            long deadline = System.nanoTime() + Duration.ofSeconds(30).toNanos();
            JsonNode view = getJson("/api/ai/jobs/" + jobId, owner.token());
            while (System.nanoTime() < deadline && !List.of("SUCCEEDED", "FAILED", "CANCELLED")
                    .contains(view.path("status").asText())) {
                worker.recoverAndWake();
                Thread.sleep(250);
                view = getJson("/api/ai/jobs/" + jobId, owner.token());
            }

            assertThat(view.path("status").asText()).as(view.toString()).isEqualTo("SUCCEEDED");
            assertThat(view.path("result").path("ai").path("clientName").asText()).isEqualTo("SUNAS");
            Map<String, Object> row = jdbc.queryForMap(
                    "SELECT attempts, ai_calls, error_code FROM ai_jobs WHERE id = ?::uuid", jobId);
            assertThat(row).containsEntry("attempts", 1).containsEntry("ai_calls", 1);
            assertThat(row.get("error_code")).isNull();
            assertThat(FAKE.chatRequestCount()).isOne();
            assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_call_logs WHERE job_id = ?::uuid",
                    Integer.class, jobId)).isOne();
        } finally {
            properties.setJobLeaseSeconds(originalLease);
        }
    }

    @Test
    void aClaimTakenOverAfterItsLeaseExpiredCannotWriteAnymore() throws Exception {
        Staff owner = aiUser();
        awaitNoActiveJobs();
        UUID id = insertRunning(owner, "EXTRACTING", 1);
        TransactionTemplate tx = new TransactionTemplate(transactionManager);

        // 回收与重新认领放在同一事务里: 重新排队的行提交前对后台线程不可见, 不会被它抢走。
        AiJobRepository.ClaimedJob second = tx.execute(status -> {
            assertThat(repository.recoverExpiredLeases()).isEqualTo(1);
            return repository.claimNext(600);
        }).orElseThrow();
        assertThat(second.id()).isEqualTo(id);
        assertThat(second.attempts()).isEqualTo(2);

        int stale = 1;
        assertThat(tx.<Optional<Boolean>>execute(status -> repository.progress(id, stale, "MATCHING", 80, 600))).isEmpty();
        assertThat(tx.<Optional<Boolean>>execute(status -> repository.cancelRequested(id, stale))).isEmpty();
        assertThat(tx.<Integer>execute(status -> repository.incrementAiCalls(id, stale, 12, 600))).isEqualTo(-1);
        assertThat(tx.<Integer>execute(status -> repository.finishSucceeded(id, stale, "{\"stale\":true}"))).isZero();
        assertThat(tx.<Integer>execute(status -> repository.finishFailed(id, stale, "INTERNAL", "x"))).isZero();
        assertThat(tx.<Integer>execute(status -> repository.finishCancelled(id, stale))).isZero();
        assertThat(tx.<Integer>execute(status -> repository.releaseForShutdown(id, stale))).isZero();
        assertThat(statusOf(id)).isEqualTo("RUNNING:null:false");

        assertThat(tx.<Optional<Boolean>>execute(status -> repository.progress(id, 2, "MATCHING", 80, 600))).contains(false);
        assertThat(tx.<Integer>execute(status -> repository.finishSucceeded(id, 2, "{\"fresh\":true}"))).isOne();
        assertThat(statusOf(id)).isEqualTo("SUCCEEDED:null:true");
        assertThat(jdbc.queryForObject("SELECT result->>'fresh' FROM ai_jobs WHERE id = ?", String.class, id))
                .isEqualTo("true");
    }

    @Test
    void aJobTheUserAlreadyCancelledIsNeverReusedForTheSameFile() throws Exception {
        Staff owner = aiUser();
        awaitNoActiveJobs();
        UUID userId = UUID.fromString(owner.userId());
        UUID running = insertRunning(owner, "MATCHING", 1);
        jdbc.update("UPDATE ai_jobs SET lease_until = now() + interval '10 minutes', created_at = now() "
                + "WHERE id = ?", running);
        TransactionTemplate tx = new TransactionTemplate(transactionManager);
        String params = "{\"mode\": \"echo\"}";
        String sha = "d".repeat(64);

        assertThat(tx.<Optional<UUID>>execute(status -> repository.findReusable(userId, KIND, params, sha, 10))).contains(running);
        jdbc.update("UPDATE ai_jobs SET cancel_requested = TRUE WHERE id = ?", running);
        assertThat(tx.<Optional<UUID>>execute(status -> repository.findReusable(userId, KIND, params, sha, 10))).isEmpty();
        jdbc.update("UPDATE ai_jobs SET status = 'CANCELLED', input_bytes = NULL WHERE id = ?", running);
    }

    @Test
    void failuresCarryThePlainMessageAndReleaseTheUpload() throws Exception {
        Staff owner = aiUser();

        String jobId = submit(owner.token(), Map.of("mode", "fail"), csv("fail"));
        JsonNode failed = awaitStatus(owner.token(), jobId, "FAILED", "SUCCEEDED");

        assertThat(failed.path("status").asText()).isEqualTo("FAILED");
        assertThat(failed.path("errorMessage").asText()).isEqualTo("测试处理器拒绝了这个文件");
        assertThat(inputReleased(jobId)).isTrue();

        MvcResult denied = submitRaw(owner.token(), Map.of("mode", "deny"), csv("deny"), "a.csv");
        assertEquals(403, denied.getResponse().getStatus(), body(denied));
        MvcResult unsupported = submitRaw(owner.token(), Map.of(), new byte[]{(byte) 0x89, 'P', 'N', 'G', 13, 10,
                26, 10, 0, 0}, "photo.png");
        assertEquals(415, unsupported.getResponse().getStatus(), body(unsupported));
        MvcResult unknownKind = mvc.perform(post("/api/ai/jobs").param("kind", "NO_SUCH_KIND")
                .contentType(MediaType.APPLICATION_OCTET_STREAM).content(csv("x"))
                .header("Authorization", "Bearer " + owner.token())).andReturn();
        assertEquals(404, unknownKind.getResponse().getStatus(), body(unknownKind));
    }

    @Test
    void perUserActiveLimitAndCancellation() throws Exception {
        Staff owner = aiUser();

        String first = submit(owner.token(), Map.of("mode", "sleep"), csv("sleep-1"));
        String second = submit(owner.token(), Map.of("mode", "sleep"), csv("sleep-2"));
        MvcResult third = submitRaw(owner.token(), Map.of("mode", "sleep"), csv("sleep-3"), "c.csv");
        assertEquals(429, third.getResponse().getStatus(), body(third));
        assertThat(json(third).path("message").asText()).isEqualTo("你已有识别任务在进行, 请稍等");

        awaitStatus(owner.token(), first, "RUNNING");
        MvcResult cancelled = mvc.perform(authed(post("/api/ai/jobs/" + first + "/cancel"), owner.token()))
                .andReturn();
        assertEquals(200, cancelled.getResponse().getStatus(), body(cancelled));
        mvc.perform(authed(post("/api/ai/jobs/" + second + "/cancel"), owner.token())).andReturn();

        assertThat(awaitStatus(owner.token(), first, "CANCELLED").path("result").isNull()).isTrue();
        awaitStatus(owner.token(), second, "CANCELLED");
        assertThat(inputReleased(first)).isTrue();
        assertThat(inputReleased(second)).isTrue();
        awaitNoActiveJobs();
    }

    @Test
    void changedPermissionsFailTheJobInsteadOfRunningWithStaleAuthority() throws Exception {
        Staff owner = aiUser();
        UUID jobId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO ai_jobs (id, kind, status, params, input_name, input_content_type, input_kind, input_size,
                                     input_sha256, input_bytes, submitted_by_user, submitted_by_employee,
                                     submitted_auth_version, submitted_auth_epoch)
                SELECT ?, ?, 'PENDING', '{"mode":"echo"}'::jsonb, 'stale.csv', 'text/csv', 'CSV', 3,
                       repeat('b', 64), 'abc'::bytea, u.id, u.employee_id, u.auth_version - 1, a.epoch
                FROM users u CROSS JOIN authorization_state a
                WHERE u.id = ?::uuid AND a.singleton_id = 1
                """, jobId, KIND, owner.userId());

        worker.recoverAndWake();
        JsonNode failed = awaitStatus(owner.token(), jobId.toString(), "FAILED", "SUCCEEDED");

        assertThat(failed.path("status").asText()).isEqualTo("FAILED");
        assertThat(failed.path("errorCode").asText()).isEqualTo("PRINCIPAL_CHANGED");
        assertThat(failed.path("errorMessage").asText()).isEqualTo("账号权限已变化, 请重新识别");
        assertThat(inputReleased(jobId.toString())).isTrue();
    }

    @Test
    void expiredLeasesFailPoisonFilesAndRetryLaterStagesOnce() throws Exception {
        Staff owner = aiUser();
        awaitNoActiveJobs();
        UUID parsing = insertRunning(owner, "LAYOUT", 1);
        UUID matchingFirst = insertRunning(owner, "MATCHING", 1);
        UUID matchingSecond = insertRunning(owner, "MATCHING", 2);
        UUID cancelAsked = insertRunning(owner, "EXTRACTING", 1);
        jdbc.update("UPDATE ai_jobs SET ai_calls = 5 WHERE id = ?", matchingFirst);
        jdbc.update("UPDATE ai_jobs SET cancel_requested = TRUE WHERE id = ?", cancelAsked);

        Integer recovered = new TransactionTemplate(transactionManager)
                .execute(status -> repository.recoverExpiredLeases());

        assertThat(recovered).isEqualTo(4);
        assertThat(statusOf(parsing)).isEqualTo("FAILED:UNPARSABLE:true");
        assertThat(statusOf(matchingFirst)).isEqualTo("PENDING:null:false");
        assertThat(jdbc.queryForObject("SELECT ai_calls FROM ai_jobs WHERE id = ?", Integer.class, matchingFirst))
                .as("a requeued job starts over with a fresh AI call budget").isZero();
        assertThat(statusOf(matchingSecond)).isEqualTo("FAILED:INTERRUPTED:true");
        // 用户已点取消的: 按取消结束, 不回到队列里空占「进行中」名额。
        assertThat(statusOf(cancelAsked)).isEqualTo("CANCELLED:null:true");
        jdbc.update("UPDATE ai_jobs SET status = 'CANCELLED', input_bytes = NULL WHERE id = ?", matchingFirst);
    }

    @Test
    void claimsSkipRowsLockedByAnotherWorker() throws Exception {
        Staff owner = aiUser();
        awaitNoActiveJobs();
        UUID first = insertPending(owner, "2020-01-01T00:00:00Z");
        UUID second = insertPending(owner, "2020-01-01T00:00:01Z");
        CountDownLatch claimed = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);

        CompletableFuture<UUID> holder = CompletableFuture.supplyAsync(() ->
                new TransactionTemplate(transactionManager).execute(status -> {
                    UUID id = repository.claimNext(600).orElseThrow().id();
                    claimed.countDown();
                    try {
                        release.await(10, TimeUnit.SECONDS);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    }
                    status.setRollbackOnly();
                    return id;
                }));
        assertThat(claimed.await(10, TimeUnit.SECONDS)).isTrue();
        UUID mine = new TransactionTemplate(transactionManager).execute(status -> {
            UUID id = repository.claimNext(600).orElseThrow().id();
            assertThat(repository.claimNext(600)).as("the locked row is skipped, not waited for").isEmpty();
            status.setRollbackOnly();
            return id;
        });
        release.countDown();

        assertThat(holder.get(10, TimeUnit.SECONDS)).isEqualTo(first);
        assertThat(mine).isEqualTo(second);
        jdbc.update("UPDATE ai_jobs SET status = 'CANCELLED', input_bytes = NULL WHERE id IN (?, ?)", first, second);
    }

    @Test
    void housekeepingFailsStaleQueueAndArchivesOldResultsJobsAndCallLogsWithoutDestroyingThem() throws Exception {
        Staff owner = aiUser();
        awaitNoActiveJobs();
        // 排队 1 小时(超过 30 分钟未开始, 但还没到 7 天删除期)。
        UUID stale = insertPending(owner, java.time.OffsetDateTime.now().minusHours(1).toString());
        jdbc.update("UPDATE ai_jobs SET updated_at=created_at WHERE id=?",stale);
        UUID oldResult = UUID.randomUUID();
        UUID ancient = UUID.randomUUID();
        insertFinished(owner, oldResult, "now() - interval '3 days'", "now() - interval '3 days'");
        insertFinished(owner, ancient, "now() - interval '9 days'", "now() - interval '9 days'");
        jdbc.update("""
                INSERT INTO ai_call_logs (created_at, purpose, ok, latency_ms)
                VALUES (now() - interval '200 days', 'OLD', true, 1), (now(), 'NEW', true, 1)
                """);

        housekeeping.purge();

        assertThat(statusOf(stale)).isEqualTo("FAILED:QUEUE_TIMEOUT:true");
        assertThat(jdbc.queryForObject("SELECT result IS NOT NULL AND result_purged_at IS NULL AND archived_at IS NOT NULL FROM ai_jobs "
                + "WHERE id = ?", Boolean.class, oldResult)).isTrue();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_jobs WHERE id = ?", Integer.class, ancient)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_call_logs WHERE purpose = 'OLD'", Integer.class))
                .isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT archived_at IS NOT NULL FROM ai_call_logs WHERE purpose='OLD'",Boolean.class)).isTrue();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_call_logs WHERE purpose = 'NEW'", Integer.class))
                .isPositive();
    }

    @Test
    void terminalRowsCannotKeepTheUpload() {
        String sql = """
                INSERT INTO ai_jobs (kind, status, input_name, input_content_type, input_kind, input_size,
                                     input_sha256, input_bytes, submitted_by_user, submitted_auth_version)
                VALUES ('X', 'SUCCEEDED', 'a', 'b', 'CSV', 1, repeat('c', 64), 'x'::bytea, gen_random_uuid(), 0)
                """;
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> jdbc.update(sql))
                .hasMessageContaining("ck_ai_jobs_terminal_input_released");
    }

    // ------------------------------------------------------------------ 造数

    private UUID insertRunning(Staff owner, String stage, int attempts) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO ai_jobs (id, kind, status, stage, params, input_name, input_content_type, input_kind,
                                     input_size, input_sha256, input_bytes, submitted_by_user, submitted_by_employee,
                                     submitted_auth_version, submitted_auth_epoch, attempts, started_at, lease_until)
                SELECT ?, ?, 'RUNNING', ?, '{"mode":"echo"}'::jsonb, 'r.csv', 'text/csv', 'CSV', 3,
                       repeat('d', 64), 'abc'::bytea, u.id, u.employee_id, u.auth_version, a.epoch, ?,
                       now() - interval '20 minutes', now() - interval '1 minute'
                FROM users u CROSS JOIN authorization_state a
                WHERE u.id = ?::uuid AND a.singleton_id = 1
                """, id, KIND, stage, attempts, owner.userId());
        return id;
    }

    private UUID insertPending(Staff owner, String createdAt) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO ai_jobs (id, kind, status, params, input_name, input_content_type, input_kind, input_size,
                                     input_sha256, input_bytes, submitted_by_user, submitted_by_employee,
                                     submitted_auth_version, submitted_auth_epoch, created_at)
                SELECT ?, ?, 'PENDING', '{"mode":"echo"}'::jsonb, 'p.csv', 'text/csv', 'CSV', 3,
                       repeat('e', 64), 'abc'::bytea, u.id, u.employee_id, u.auth_version, a.epoch, ?::timestamptz
                FROM users u CROSS JOIN authorization_state a
                WHERE u.id = ?::uuid AND a.singleton_id = 1
                """, id, KIND, createdAt, owner.userId());
        return id;
    }

    private void insertFinished(Staff owner, UUID id, String createdAt, String finishedAt) {
        jdbc.update("""
                INSERT INTO ai_jobs (id, kind, status, params, input_name, input_content_type, input_kind, input_size,
                                     input_sha256, result, submitted_by_user, submitted_auth_version,
                                     created_at, finished_at)
                VALUES (?, ?, 'SUCCEEDED', '{}'::jsonb, 'f.csv', 'text/csv', 'CSV', 3, repeat('f', 64),
                        '{"x":1}'::jsonb, ?::uuid, 0, %s, %s)
                """.formatted(createdAt, finishedAt), id, KIND, owner.userId());
    }

    private String statusOf(UUID id) {
        return jdbc.queryForObject(
                "SELECT status || ':' || coalesce(error_code, 'null') || ':' || (input_bytes IS NULL) "
                        + "FROM ai_jobs WHERE id = ?", String.class, id);
    }
}
