package com.uten.imp.features.ai.job;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/**
 * ai_jobs 队列的全部 SQL(ADR-133)。调用方负责事务边界; 这里每个方法都是一两条语句。
 *
 * <p>约定: 进入终态(SUCCEEDED/FAILED/CANCELLED)的每一条 UPDATE 都在同一条语句里清空
 * {@code input_bytes}(数据库 CHECK {@code ck_ai_jobs_terminal_input_released} 兜底);
 * 所有工作线程侧的写入都带 {@code status = 'RUNNING' AND attempts = :attempt} 条件(认领令牌: 每次认领
 * attempts 加一), 影响 0 行说明任务已被取消、清理、清库, 或租约过期后被重新认领 —— 调用方安静停止,
 * 被取代的旧处理线程不会改写新一次认领的任务行。
 */
@Component
class AiJobRepository {

    static final String PENDING = "PENDING";
    static final String RUNNING = "RUNNING";
    static final String SUCCEEDED = "SUCCEEDED";
    static final String FAILED = "FAILED";
    static final String CANCELLED = "CANCELLED";

    private static final String VIEW_COLUMNS = """
            id, kind, status, stage, progress, cancel_requested, params::text AS params_json,
            input_name, input_kind, input_size, submitted_by_user, created_at, started_at, finished_at,
            error_code, error_message, used_at, result_purged_at, (result IS NOT NULL) AS has_result
            """;

    private final NamedParameterJdbcTemplate jdbc;

    AiJobRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** 不含上传文件与结果的任务行。 */
    record JobRow(UUID id, String kind, String status, String stage, int progress, boolean cancelRequested,
                  String paramsJson, String inputName, String inputKind, long inputSize, UUID submittedByUser,
                  OffsetDateTime createdAt, OffsetDateTime startedAt, OffsetDateTime finishedAt, String errorCode,
                  String errorMessage, OffsetDateTime usedAt, OffsetDateTime resultPurgedAt, boolean hasResult) {
    }

    /** 被认领的任务(含上传文件)。 */
    record ClaimedJob(UUID id, String kind, String paramsJson, String inputName, String inputContentType,
                      String inputKind, long inputSize, String inputSha256, byte[] inputBytes, UUID submittedByUser,
                      UUID submittedByEmployee, long submittedAuthVersion, Long submittedAuthEpoch, int attempts,
                      int aiCalls) {
    }

    /** 新任务。 */
    record NewJob(UUID id, String kind, String paramsJson, String inputName, String inputContentType,
                  String inputKind, long inputSize, String inputSha256, byte[] inputBytes, UUID submittedByUser,
                  UUID submittedByEmployee, long submittedAuthVersion, long submittedAuthEpoch) {
    }

    private static final RowMapper<JobRow> VIEW_MAPPER = (rs, rowNum) -> new JobRow(
            rs.getObject("id", UUID.class),
            rs.getString("kind"),
            rs.getString("status"),
            rs.getString("stage"),
            rs.getInt("progress"),
            rs.getBoolean("cancel_requested"),
            rs.getString("params_json"),
            rs.getString("input_name"),
            rs.getString("input_kind"),
            rs.getLong("input_size"),
            rs.getObject("submitted_by_user", UUID.class),
            rs.getObject("created_at", OffsetDateTime.class),
            rs.getObject("started_at", OffsetDateTime.class),
            rs.getObject("finished_at", OffsetDateTime.class),
            rs.getString("error_code"),
            rs.getString("error_message"),
            rs.getObject("used_at", OffsetDateTime.class),
            rs.getObject("result_purged_at", OffsetDateTime.class),
            rs.getBoolean("has_result"));

    // ------------------------------------------------------------------ 提交与读取(请求线程)

    /** 同一提交人的写入串行(限额与幂等检查不被并发请求绕过)。 */
    void lockSubmitter(UUID userId) {
        jdbc.query("SELECT pg_advisory_xact_lock(hashtextextended(:key, 0))",
                new MapSqlParameterSource("key", "ai_jobs:" + userId), rs -> null);
    }

    int countActive(UUID userId) {
        return count("""
                SELECT count(*) FROM ai_jobs
                WHERE submitted_by_user = :user AND status IN ('PENDING', 'RUNNING')
                """, new MapSqlParameterSource("user", userId));
    }

    int countToday(UUID userId) {
        return count("""
                SELECT count(*) FROM ai_jobs
                WHERE submitted_by_user = :user
                  AND created_at >= (date_trunc('day', now() AT TIME ZONE 'Asia/Shanghai') AT TIME ZONE 'Asia/Shanghai')
                """, new MapSqlParameterSource("user", userId));
    }

    int countPending() {
        return count("SELECT count(*) FROM ai_jobs WHERE status = 'PENDING'", new MapSqlParameterSource());
    }

    /** 可复用的任务: 已请求取消的(马上会以「已取消」结束)不复用。 */
    Optional<UUID> findReusable(UUID userId, String kind, String paramsJson, String sha256, int windowMinutes) {
        List<UUID> ids = jdbc.queryForList("""
                SELECT id FROM ai_jobs
                WHERE submitted_by_user = :user AND kind = :kind AND input_sha256 = :sha
                  AND params = CAST(:params AS jsonb)
                  AND status IN ('PENDING', 'RUNNING', 'SUCCEEDED') AND NOT cancel_requested
                  AND used_at IS NULL AND result_purged_at IS NULL
                  AND created_at > now() - make_interval(mins => :window)
                ORDER BY created_at DESC
                LIMIT 1
                """, new MapSqlParameterSource()
                .addValue("user", userId)
                .addValue("kind", kind)
                .addValue("sha", sha256)
                .addValue("params", paramsJson)
                .addValue("window", windowMinutes), UUID.class);
        return ids.stream().findFirst();
    }

    void insert(NewJob job) {
        jdbc.update("""
                INSERT INTO ai_jobs (id, kind, status, params, input_name, input_content_type, input_kind,
                                     input_size, input_sha256, input_bytes, submitted_by_user,
                                     submitted_by_employee, submitted_auth_version, submitted_auth_epoch)
                VALUES (:id, :kind, 'PENDING', CAST(:params AS jsonb), :name, :contentType, :inputKind,
                        :size, :sha, :bytes, :user, :employee, :authVersion, :authEpoch)
                """, new MapSqlParameterSource()
                .addValue("id", job.id())
                .addValue("kind", job.kind())
                .addValue("params", job.paramsJson())
                .addValue("name", job.inputName())
                .addValue("contentType", job.inputContentType())
                .addValue("inputKind", job.inputKind())
                .addValue("size", job.inputSize())
                .addValue("sha", job.inputSha256())
                .addValue("bytes", job.inputBytes())
                .addValue("user", job.submittedByUser())
                .addValue("employee", job.submittedByEmployee())
                .addValue("authVersion", job.submittedAuthVersion())
                .addValue("authEpoch", job.submittedAuthEpoch()));
    }

    Optional<JobRow> findOwned(UUID id, UUID userId) {
        return jdbc.query("SELECT " + VIEW_COLUMNS + " FROM ai_jobs WHERE id = :id AND submitted_by_user = :user",
                new MapSqlParameterSource().addValue("id", id).addValue("user", userId), VIEW_MAPPER)
                .stream().findFirst();
    }

    Optional<String> resultJson(UUID id) {
        return jdbc.queryForList("SELECT result::text FROM ai_jobs WHERE id = :id AND result IS NOT NULL",
                new MapSqlParameterSource("id", id), String.class).stream().findFirst();
    }
    Map<String,Object> historyMetadata(UUID id,UUID user) {
        var rows=jdbc.queryForList("""
                SELECT used_at AS "usedAt",used_doc_type AS "usedDocumentKind",used_doc_id AS "usedDocumentId",
                    archived_at AS "archivedAt",archived_by AS "archivedBy",archive_reason AS "archiveReason"
                FROM ai_jobs WHERE id=:id AND submitted_by_user=:user
                """,new MapSqlParameterSource("id",id).addValue("user",user));
        return rows.isEmpty()?Map.of():rows.getFirst();
    }

    /** 排队中的任务直接取消(同一语句清空上传文件)。 */
    int cancelPending(UUID id, UUID userId) {
        return jdbc.update("""
                UPDATE ai_jobs
                SET status = 'CANCELLED', cancel_requested = TRUE, input_bytes = NULL,
                    finished_at = now(), updated_at = now(), lease_until = NULL
                WHERE id = :id AND submitted_by_user = :user AND status = 'PENDING'
                """, new MapSqlParameterSource().addValue("id", id).addValue("user", userId));
    }

    /** 处理中的任务打上取消标记, 由工作线程在阶段之间停下。 */
    int requestCancel(UUID id, UUID userId) {
        return jdbc.update("""
                UPDATE ai_jobs SET cancel_requested = TRUE, updated_at = now()
                WHERE id = :id AND submitted_by_user = :user AND status = 'RUNNING'
                """, new MapSqlParameterSource().addValue("id", id).addValue("user", userId));
    }

    // ------------------------------------------------------------------ 结果使用(AiJobUsagePort)

    /** 本人、成功、从未被单据采用且未清空的结果。 */
    Optional<String> ownedUsableResult(UUID id, UUID userId) {
        return jdbc.queryForList("""
                SELECT result::text FROM ai_jobs
                WHERE id = :id AND submitted_by_user = :user AND status = 'SUCCEEDED'
                  AND used_at IS NULL AND result IS NOT NULL AND result_purged_at IS NULL
                """, new MapSqlParameterSource().addValue("id", id).addValue("user", userId), String.class)
                .stream().findFirst();
    }

    int reserveLearning(UUID id, UUID user, String docType, UUID docId, java.time.OffsetDateTime retryUntil) {
        return jdbc.update("""
                UPDATE ai_jobs SET used_doc_type=:type,used_doc_id=:doc,
                    learning_retry_until=GREATEST(COALESCE(learning_retry_until,'-infinity'::timestamptz),:until),updated_at=now()
                WHERE id=:id AND submitted_by_user=:actor AND kind='SALES_DOCUMENT_INTAKE' AND status='SUCCEEDED' AND result IS NOT NULL
                    AND used_at IS NULL AND (used_doc_id IS NULL OR (used_doc_type=:type AND used_doc_id=:doc))
                """, new MapSqlParameterSource().addValue("id",id).addValue("actor",user)
                .addValue("type",docType).addValue("doc",docId).addValue("until",java.sql.Timestamp.from(retryUntil.toInstant())));
    }

    int reserveLearningForSave(UUID id,UUID user,String type,UUID doc,java.time.OffsetDateTime until,
            java.util.Set<String> keys,boolean headerUsed) {
        return jdbc.update("""
                UPDATE ai_jobs SET used_doc_type=:type,used_doc_id=:doc,
                    learning_retry_until=GREATEST(COALESCE(learning_retry_until,'-infinity'::timestamptz),:until),updated_at=now()
                WHERE id=:id AND submitted_by_user=:actor AND kind='SALES_DOCUMENT_INTAKE' AND status='SUCCEEDED' AND result IS NOT NULL
                    AND used_at IS NULL AND (used_doc_id IS NULL OR (used_doc_type=:type AND used_doc_id=:doc))
                    AND (:header OR EXISTS(SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(result->'lines')='array'
                        THEN result->'lines' ELSE '[]'::jsonb END) AS source(line) WHERE source.line->>'key' IN(:keys)))
                """,new MapSqlParameterSource().addValue("id",id).addValue("actor",user).addValue("type",type).addValue("doc",doc)
                .addValue("until",java.sql.Timestamp.from(until.toInstant())).addValue("header",headerUsed)
                .addValue("keys",keys.isEmpty()?java.util.List.of("__no_saved_source_line__"):keys));
    }

    /**
     * 记下采用去向并在同一语句里清空结果。第一张单据生效: 已被另一张单据采用的任务影响 0 行(去向不被改写,
     * 同一结果不能喂给第二张单据的学习); 同一张单据重复标记是无害的重放。
     */
    int markUsed(UUID id, UUID userId, String docType, UUID docId) {
        return jdbc.update("""
                UPDATE ai_jobs
                SET used_at = COALESCE(used_at, now()), used_doc_type = :docType, used_doc_id = :docId,
                    learning_retry_until=NULL, updated_at = now()
                WHERE id = :id AND submitted_by_user = :user AND status = 'SUCCEEDED'
                  AND (used_doc_id IS NULL OR (used_doc_type=:docType AND used_doc_id=:docId))
                  AND (used_at IS NULL OR (used_doc_type = :docType AND used_doc_id = :docId))
                """, new MapSqlParameterSource()
                .addValue("id", id)
                .addValue("user", userId)
                .addValue("docType", docType)
                .addValue("docId", docId));
    }

    // ------------------------------------------------------------------ 工作线程

    /**
     * 按创建顺序认领一个排队任务(FOR UPDATE SKIP LOCKED), 设置租约并把尝试次数加一; 阶段重置为
     * {@code STARTING}(重建主体中, 不属于解析阶段), 重新排队的任务从头处理。返回的 {@code attempts}
     * 就是这次认领的令牌, 之后工作线程的每一次写入都要带上它。
     */
    Optional<ClaimedJob> claimNext(int leaseSeconds) {
        return jdbc.query("""
                UPDATE ai_jobs
                SET status = 'RUNNING', attempts = attempts + 1, started_at = COALESCE(started_at, now()),
                    stage = 'STARTING', progress = 0,
                    lease_until = now() + make_interval(secs => :lease), updated_at = now()
                WHERE id = (SELECT id FROM ai_jobs
                            WHERE status = 'PENDING' AND NOT cancel_requested
                            ORDER BY created_at, id
                            LIMIT 1
                            FOR UPDATE SKIP LOCKED)
                RETURNING id, kind, params::text AS params_json, input_name, input_content_type, input_kind,
                          input_size, input_sha256, input_bytes, submitted_by_user, submitted_by_employee,
                          submitted_auth_version, submitted_auth_epoch, attempts, ai_calls
                """, new MapSqlParameterSource("lease", leaseSeconds), AiJobRepository::claimed)
                .stream().findFirst();
    }

    private static ClaimedJob claimed(ResultSet rs, int rowNum) throws SQLException {
        long epoch = rs.getLong("submitted_auth_epoch");
        Long authEpoch = rs.wasNull() ? null : epoch;
        return new ClaimedJob(
                rs.getObject("id", UUID.class),
                rs.getString("kind"),
                rs.getString("params_json"),
                rs.getString("input_name"),
                rs.getString("input_content_type"),
                rs.getString("input_kind"),
                rs.getLong("input_size"),
                rs.getString("input_sha256"),
                rs.getBytes("input_bytes"),
                rs.getObject("submitted_by_user", UUID.class),
                rs.getObject("submitted_by_employee", UUID.class),
                rs.getLong("submitted_auth_version"),
                authEpoch,
                rs.getInt("attempts"),
                rs.getInt("ai_calls"));
    }

    /**
     * 回收租约过期的处理中任务: 用户已请求取消的按取消结束; 还在读文件/判版式阶段(或阶段未知)的判
     * 「文件无法解析」不再重试(防止坏文件反复拖垮进程); 之后的阶段尝试不足 2 次的重新排队(AI 调用次数
     * 归零, 重新排队的任务从头处理), 否则判失败。
     */
    int recoverExpiredLeases() {
        int cancelled = jdbc.update("""
                UPDATE ai_jobs
                SET status = 'CANCELLED', input_bytes = NULL, finished_at = now(), updated_at = now(),
                    lease_until = NULL
                WHERE status = 'RUNNING' AND lease_until < now() AND cancel_requested
                """, new MapSqlParameterSource());
        int poisoned = jdbc.update("""
                UPDATE ai_jobs
                SET status = 'FAILED', error_code = 'UNPARSABLE',
                    error_message = '文件无法解析, 请检查文件是否完整后重新上传',
                    input_bytes = NULL, finished_at = now(), updated_at = now(), lease_until = NULL
                WHERE status = 'RUNNING' AND lease_until < now()
                  AND (stage IS NULL OR stage IN ('READING', 'PARSING', 'LAYOUT'))
                """, new MapSqlParameterSource());
        int exhausted = jdbc.update("""
                UPDATE ai_jobs
                SET status = 'FAILED', error_code = 'INTERRUPTED',
                    error_message = '识别中途中断了, 请重新上传',
                    input_bytes = NULL, finished_at = now(), updated_at = now(), lease_until = NULL
                WHERE status = 'RUNNING' AND lease_until < now() AND attempts >= 2
                """, new MapSqlParameterSource());
        int requeued = jdbc.update("""
                UPDATE ai_jobs
                SET status = 'PENDING', lease_until = NULL, ai_calls = 0, updated_at = now()
                WHERE status = 'RUNNING' AND lease_until < now() AND attempts < 2 AND NOT cancel_requested
                """, new MapSqlParameterSource());
        return cancelled + poisoned + exhausted + requeued;
    }

    /**
     * 报告阶段并续租(阶段/进度为空表示不改, 只续租)。返回当前的取消标记; 任务已不属于这次认领
     * (被取消/清理/清库, 或租约过期后被重新认领)返回空。
     */
    Optional<Boolean> progress(UUID id, int attempt, String stage, Integer percent, int leaseSeconds) {
        return jdbc.queryForList("""
                UPDATE ai_jobs
                SET stage = COALESCE(CAST(:stage AS varchar), stage),
                    progress = COALESCE(CAST(:percent AS integer), progress),
                    lease_until = now() + make_interval(secs => :lease), updated_at = now()
                WHERE id = :id AND status = 'RUNNING' AND attempts = :attempt
                RETURNING cancel_requested
                """, claim(id, attempt)
                .addValue("stage", stage)
                .addValue("percent", percent)
                .addValue("lease", leaseSeconds), Boolean.class).stream().findFirst();
    }

    /** 当前取消标记; 任务已不属于这次认领返回空。 */
    Optional<Boolean> cancelRequested(UUID id, int attempt) {
        return jdbc.queryForList("""
                SELECT cancel_requested FROM ai_jobs WHERE id = :id AND status = 'RUNNING' AND attempts = :attempt
                """, claim(id, attempt), Boolean.class).stream().findFirst();
    }

    /**
     * AI 调用次数加一(不超过上限)并续租。返回新的次数; 已达上限返回 -2; 任务已不属于这次认领返回 -1。
     */
    int incrementAiCalls(UUID id, int attempt, int maxCalls, int leaseSeconds) {
        List<Integer> updated = jdbc.queryForList("""
                UPDATE ai_jobs
                SET ai_calls = ai_calls + 1, lease_until = now() + make_interval(secs => :lease), updated_at = now()
                WHERE id = :id AND status = 'RUNNING' AND attempts = :attempt AND ai_calls < :max
                RETURNING ai_calls
                """, claim(id, attempt)
                .addValue("max", maxCalls)
                .addValue("lease", leaseSeconds), Integer.class);
        if (!updated.isEmpty()) {
            return updated.get(0);
        }
        return cancelRequested(id, attempt).isPresent() ? -2 : -1;
    }

    /** 成功; 处理中途被请求取消的按取消结束(不保存结果)。 */
    int finishSucceeded(UUID id, int attempt, String resultJson) {
        return jdbc.update("""
                UPDATE ai_jobs
                SET status = CASE WHEN cancel_requested THEN 'CANCELLED' ELSE 'SUCCEEDED' END,
                    result = CASE WHEN cancel_requested THEN NULL ELSE CAST(:result AS jsonb) END,
                    stage = 'DONE', progress = 100, input_bytes = NULL,
                    finished_at = now(), updated_at = now(), lease_until = NULL
                WHERE id = :id AND status = 'RUNNING' AND attempts = :attempt
                """, claim(id, attempt).addValue("result", resultJson));
    }

    int finishFailed(UUID id, int attempt, String errorCode, String errorMessage) {
        return jdbc.update("""
                UPDATE ai_jobs
                SET status = 'FAILED', error_code = :code, error_message = :message, input_bytes = NULL,
                    finished_at = now(), updated_at = now(), lease_until = NULL
                WHERE id = :id AND status = 'RUNNING' AND attempts = :attempt
                """, claim(id, attempt)
                .addValue("code", truncate(errorCode, 48))
                .addValue("message", truncate(errorMessage, 1000)));
    }

    int finishCancelled(UUID id, int attempt) {
        return jdbc.update("""
                UPDATE ai_jobs
                SET status = 'CANCELLED', input_bytes = NULL, finished_at = now(), updated_at = now(),
                    lease_until = NULL
                WHERE id = :id AND status = 'RUNNING' AND attempts = :attempt
                """, claim(id, attempt));
    }

    /** 服务正常停机: 放回队列且不计这次尝试(不触发坏文件判定)。 */
    int releaseForShutdown(UUID id, int attempt) {
        return jdbc.update("""
                UPDATE ai_jobs
                SET status = 'PENDING', attempts = GREATEST(attempts - 1, 0), lease_until = NULL,
                    ai_calls = 0, updated_at = now()
                WHERE id = :id AND status = 'RUNNING' AND attempts = :attempt
                """, claim(id, attempt));
    }

    private static MapSqlParameterSource claim(UUID id, int attempt) {
        return new MapSqlParameterSource().addValue("id", id).addValue("attempt", attempt);
    }

    // ------------------------------------------------------------------ 清理

    /** 排队太久没人处理(例如后台线程未运行)的任务判失败并清空上传文件。 */
    int failStalePending(int minutes) {
        return jdbc.update("""
                UPDATE ai_jobs
                SET status = 'FAILED', error_code = 'QUEUE_TIMEOUT',
                    error_message = '识别任务排队太久没有开始, 请稍后重新上传',
                    input_bytes = NULL, finished_at = now(), updated_at = now()
                WHERE status = 'PENDING' AND updated_at < now() - make_interval(mins => :minutes)
                """, new MapSqlParameterSource("minutes", minutes));
    }

    /**
     * 清空结果: 结束超过保留期的; 以及(兜底)已被单据采用却还留着结果的 —— 正常情况下
     * {@link #markUsed} 已在同一语句里清空。
     */
    int purgeResults(int retentionHours) {
        return jdbc.update("""
                WITH candidates AS (
                    SELECT id FROM ai_jobs job
                    WHERE archived_at IS NULL AND status IN ('SUCCEEDED','FAILED','CANCELLED') AND finished_at>=created_at AND finished_at<=now()
                      AND result IS NOT NULL AND (learning_retry_until IS NULL OR learning_retry_until < now())
                      AND (used_at IS NOT NULL OR finished_at < now() - make_interval(hours => :hours))
                      AND NOT EXISTS(SELECT 1 FROM sales_document_learning_receipts receipt
                          WHERE ((receipt.doc_type=job.used_doc_type AND receipt.doc_id=job.used_doc_id)
                              OR (receipt.actor_user_id=job.submitted_by_user
                                  AND (receipt.request_payload->>'intakeJobId'=CAST(job.id AS text)
                                      OR jsonb_exists(receipt.request_payload->'additionalIntakeJobIds',CAST(job.id AS text)))))
                            AND EXISTS(SELECT 1 FROM jsonb_each(receipt.steps) step WHERE step.value->>'status'='RUNNING'))
                    ORDER BY finished_at,id LIMIT 1000 FOR UPDATE SKIP LOCKED
                )
                UPDATE ai_jobs job
                SET archived_at=now(),archived_by='system:ai-housekeeping',archive_reason='RESULT_RETENTION_WINDOW',updated_at=now()
                FROM candidates WHERE job.id=candidates.id
                """, new MapSqlParameterSource("hours", retentionHours));
    }

    /**
     * 从实际结束时间计算任务保留期；缺少结束时间的历史行保留待核验。
     * 结果及学习重试各有自己的期限，任务期限不能越过它们删除载体。
     * 每批最多 1000 行，跳过正在使用/更新的任务，避免清理阻塞前台。
     */
    int deleteFinishedOlderThan(int days) {
        return jdbc.update("""
                WITH candidates AS (
                    SELECT id FROM ai_jobs job
                    WHERE archived_at IS NULL AND status IN ('SUCCEEDED', 'FAILED', 'CANCELLED')
                      AND finished_at < now() - make_interval(days => :days)
                      AND finished_at >= created_at
                      AND result IS NULL
                      AND (learning_retry_until IS NULL OR learning_retry_until < now())
                      AND NOT EXISTS(SELECT 1 FROM sales_quote_template_candidates candidate
                          WHERE candidate.job_id=job.id AND candidate.expires_at>now())
                      AND NOT EXISTS(SELECT 1 FROM sales_document_learning_receipts receipt
                          WHERE ((receipt.doc_type=job.used_doc_type AND receipt.doc_id=job.used_doc_id)
                              OR (receipt.actor_user_id=job.submitted_by_user
                                  AND (receipt.request_payload->>'intakeJobId'=CAST(job.id AS text)
                                      OR jsonb_exists(receipt.request_payload->'additionalIntakeJobIds',CAST(job.id AS text)))))
                            AND EXISTS(SELECT 1 FROM jsonb_each(receipt.steps) step WHERE step.value->>'status'='RUNNING'))
                    ORDER BY finished_at, id
                    LIMIT 1000
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE ai_jobs job SET archived_at=now(),archived_by='system:ai-housekeeping',archive_reason='JOB_RETENTION_WINDOW',updated_at=now()
                FROM candidates
                WHERE job.id = candidates.id
                """, new MapSqlParameterSource("days", days));
    }

    private int count(String sql, MapSqlParameterSource params) {
        Integer value = jdbc.queryForObject(sql, params, Integer.class);
        return value == null ? 0 : value;
    }

    private static String truncate(String value, int max) {
        if (value == null || value.length() <= max) {
            return value;
        }
        return value.substring(0, max);
    }
}
