-- System/unattributed calls retain a NULL owner. Never assign them to a fake
-- employee, exclude them from global usage, or rewrite the original call log.
-- V815 bytes are immutable. Its compatibility callback only filters its
-- intermediate backfill; this forward migration restores every original bucket.
ALTER TABLE public.ai_usage_daily DROP CONSTRAINT ai_usage_daily_pkey;
ALTER TABLE public.ai_usage_daily ALTER COLUMN user_id DROP NOT NULL;
ALTER TABLE public.ai_usage_daily ADD CONSTRAINT ai_usage_daily_owner_day_key
    UNIQUE NULLS NOT DISTINCT (user_id, usage_date);

COMMENT ON COLUMN public.ai_usage_daily.user_id IS
    '真实调用账号; NULL 为系统或未归属调用, 计入全站用量但不冒充员工或参与个人限额';

INSERT INTO public.ai_usage_daily (user_id, usage_date, calls, ok_calls, input_tokens, output_tokens)
SELECT user_id, (created_at AT TIME ZONE 'Asia/Shanghai')::date,
       count(*), count(*) FILTER (WHERE ok),
       coalesce(sum(input_tokens), 0), coalesce(sum(output_tokens), 0)
FROM public.ai_call_logs
GROUP BY 1, 2
ON CONFLICT (user_id, usage_date) DO UPDATE SET
    calls = EXCLUDED.calls, ok_calls = EXCLUDED.ok_calls,
    input_tokens = EXCLUDED.input_tokens, output_tokens = EXCLUDED.output_tokens;

DO $verify_usage_backfill$
BEGIN
    IF EXISTS (
        SELECT 1 FROM (
            SELECT user_id, (created_at AT TIME ZONE 'Asia/Shanghai')::date AS usage_date,
                   count(*) AS calls, count(*) FILTER (WHERE ok) AS ok_calls,
                   coalesce(sum(input_tokens), 0) AS input_tokens,
                   coalesce(sum(output_tokens), 0) AS output_tokens
            FROM public.ai_call_logs GROUP BY 1, 2
        ) original
        LEFT JOIN public.ai_usage_daily summary
          ON summary.user_id IS NOT DISTINCT FROM original.user_id
         AND summary.usage_date = original.usage_date
        WHERE summary.calls IS DISTINCT FROM original.calls
           OR summary.ok_calls IS DISTINCT FROM original.ok_calls
           OR summary.input_tokens IS DISTINCT FROM original.input_tokens
           OR summary.output_tokens IS DISTINCT FROM original.output_tokens
    ) THEN
        RAISE EXCEPTION 'V820 AI usage backfill differs from original call logs';
    END IF;
END $verify_usage_backfill$;
