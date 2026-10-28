package com.uten.imp.features.admin.serverstatus;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.time.Instant;
import java.util.Collection;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * 治理类后台任务完成回执的持久层（B3，V954）。
 *
 * <p>内存注册表重启即空；本表按 {@link ScheduledTaskCatalog#durableEvidenceTasks()}
 * 只写低频治理任务的完成事实（开始/结束/耗时/结果/错误类型），让服务器状态页在
 * 重启后仍能回答「这些任务最近一次是什么时候、成没成功」。高频轮询任务不写本表，
 * 避免运行证据被秒级刷新刷屏。
 *
 * <p>写入失败只记日志、绝不影响任务本身：持久证据是观测增强，不是任务执行的前置条件。
 */
@Component
public class ScheduledTaskRunStore {

    private final JdbcTemplate jdbc;

    public ScheduledTaskRunStore(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public record PersistedRun(
            String taskKey, Instant startedAt, Instant finishedAt,
            long durationMs, String outcome, String errorType) {}

    /** 追加一条完成回执。异常向上抛出, 由调用方(注册表钩子)兜底吞掉。 */
    public void append(String taskKey, Instant startedAt, Instant finishedAt,
                       Long durationMs, String errorType) {
        jdbc.update("""
                INSERT INTO scheduled_task_runs(
                    task_key, started_at, finished_at, duration_ms, outcome, error_type)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                taskKey,
                java.sql.Timestamp.from(startedAt),
                java.sql.Timestamp.from(finishedAt),
                durationMs == null ? 0L : durationMs,
                errorType == null ? "SUCCESS" : "FAILURE",
                errorType);
    }

    /** 每个给定任务键的最近一次完成回执（状态页重启后合并显示用）。 */
    public Map<String, PersistedRun> latestRuns(Collection<String> taskKeys) {
        if (taskKeys == null || taskKeys.isEmpty()) {
            return Map.of();
        }
        Map<String, PersistedRun> latest = new HashMap<>();
        for (String key : taskKeys) {
            List<PersistedRun> rows = jdbc.query("""
                    SELECT task_key, started_at, finished_at, duration_ms, outcome, error_type
                    FROM scheduled_task_runs
                    WHERE task_key = ?
                    ORDER BY started_at DESC, id DESC
                    LIMIT 1
                    """,
                    (rs, n) -> new PersistedRun(
                            rs.getString("task_key"),
                            rs.getTimestamp("started_at").toInstant(),
                            rs.getTimestamp("finished_at").toInstant(),
                            rs.getLong("duration_ms"),
                            rs.getString("outcome"),
                            rs.getString("error_type")),
                    key);
            rows.stream().findFirst().ifPresent(run -> latest.put(run.taskKey(), run));
        }
        return latest;
    }
}
