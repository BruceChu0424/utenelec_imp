-- Test measurements and their estimates are business data, not master settings.
-- Change the reset policy only; this migration never clears any existing row.
DO $weight_reset_policy$
DECLARE
    definition text;
    relation_name text;
    anchor text;
BEGIN
    SELECT pg_get_functiondef('public.business_data_reset()'::regprocedure) INTO definition;
    FOREACH relation_name IN ARRAY ARRAY['goods_weight_observations', 'goods_weight_estimates'] LOOP
        anchor := '(''' || relation_name || ''', ''PRESERVE'')';
        IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1 THEN
            RAISE EXCEPTION 'V817 reset policy anchor missing or repeated for %', relation_name;
        END IF;
        definition := replace(definition, anchor, '(''' || relation_name || ''', ''CLEAR'')');
    END LOOP;
    IF position('(''goods_weight_profiles'', ''PRESERVE'')' IN definition) = 0
       OR position('business_reset_generation = business_reset_generation + 1' IN definition) = 0 THEN
        RAISE EXCEPTION 'V817 must preserve weight settings and the atomic business reset generation';
    END IF;
    EXECUTE definition;
END $weight_reset_policy$;

COMMENT ON TABLE goods_weight_observations IS
    '单重学习的称重观测; 清空测试业务数据时一并清除, 日常操作保留来源留痕 (V817)';
COMMENT ON TABLE goods_weight_estimates IS
    '称重观测计算的单重估计; 清空测试业务数据时一并清除, 货品称重设置独立保留 (V817)';
