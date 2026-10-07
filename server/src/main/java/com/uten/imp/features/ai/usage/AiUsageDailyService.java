package com.uten.imp.features.ai.usage;

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * AI 用量日汇总(ai_usage_daily, ADR-164)。
 *
 * <p>ai_call_logs 只留 180 天技术记录, 月/年视图需要更长历史, 因此由清理任务把用量按人按日
 * 归档汇总到这里。两步都按上海日划分(与 todayTokens 同口径, 不依赖数据库会话时区):
 * 终日回填只补「上一次已汇总的下一天 .. 前天」的缺行(DO NOTHING); 昨天与今天两天整日
 * 重算覆盖(upsert 幂等), 因为一天内调用会不断追加。昨天必须每天跟着重算一次: 昨天最后一次
 * 刷新运行之后、午夜之前落账的调用是「跨天尾巴」, 回填是 DO NOTHING 修正不了已有行, 只有
 * 次日的重算覆盖才能把尾巴并进昨天的最终值。日边界是中国无夏令时的固定偏移, 日期比较与
 * timestamptz 范围等价。
 */
@Service
public class AiUsageDailyService {

    /** 本次汇总的计数: 终日新补行数(仅前天以前的缺口)与重算行数(昨天+今天, 每次都算 update, 包括无变化的行)。 */
    public record Rollup(int backfilled, int refreshed) {}

    private final NamedParameterJdbcTemplate jdbc;

    public AiUsageDailyService(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @Transactional
    public Rollup rollup() {
        // 终日回填: 只补昨天之前的缺口(昨天的行由 refresh 覆盖, 不靠回填)。
        int backfilled = jdbc.update("""
                WITH bounds AS (
                  SELECT COALESCE(
                           (SELECT max(usage_date) FROM ai_usage_daily
                            WHERE usage_date < (now() AT TIME ZONE 'Asia/Shanghai')::date - 1) + 1,
                           (SELECT min((created_at AT TIME ZONE 'Asia/Shanghai')::date) FROM ai_call_logs),
                           (now() AT TIME ZONE 'Asia/Shanghai')::date - 1) AS start_day,
                         (now() AT TIME ZONE 'Asia/Shanghai')::date - 2 AS end_day
                ), days AS (
                  SELECT generate_series(start_day, end_day, INTERVAL '1 day')::date AS usage_date
                  FROM bounds
                )
                INSERT INTO ai_usage_daily (user_id, usage_date, calls, ok_calls, input_tokens, output_tokens)
                SELECT l.user_id, d.usage_date, count(*), count(*) FILTER (WHERE l.ok),
                       coalesce(sum(l.input_tokens), 0), coalesce(sum(l.output_tokens), 0)
                FROM days d JOIN ai_call_logs l
                  ON l.created_at >= d.usage_date::timestamp AT TIME ZONE 'Asia/Shanghai'
                 AND l.created_at < (d.usage_date + 1)::timestamp AT TIME ZONE 'Asia/Shanghai'
                GROUP BY l.user_id, d.usage_date
                ON CONFLICT DO NOTHING
                """, new MapSqlParameterSource());
        // 昨天与今天整日重算: 今天随时在追加, 昨天还有跨天尾巴要并进来(见类注释)。
        int refreshed = jdbc.update("""
                WITH days AS (
                  SELECT generate_series((now() AT TIME ZONE 'Asia/Shanghai')::date - 1,
                                         (now() AT TIME ZONE 'Asia/Shanghai')::date,
                                         INTERVAL '1 day')::date AS usage_date
                )
                INSERT INTO ai_usage_daily (user_id, usage_date, calls, ok_calls, input_tokens, output_tokens)
                SELECT l.user_id, d.usage_date, count(*), count(*) FILTER (WHERE l.ok),
                       coalesce(sum(l.input_tokens), 0), coalesce(sum(l.output_tokens), 0)
                FROM days d JOIN ai_call_logs l
                  ON l.created_at >= d.usage_date::timestamp AT TIME ZONE 'Asia/Shanghai'
                 AND l.created_at < (d.usage_date + 1)::timestamp AT TIME ZONE 'Asia/Shanghai'
                GROUP BY l.user_id, d.usage_date
                ON CONFLICT (user_id, usage_date) DO UPDATE SET
                    calls = EXCLUDED.calls, ok_calls = EXCLUDED.ok_calls,
                    input_tokens = EXCLUDED.input_tokens, output_tokens = EXCLUDED.output_tokens
                """, new MapSqlParameterSource());
        return new Rollup(backfilled, refreshed);
    }
}
