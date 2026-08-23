-- V391: 修复 fn_validate_preplan_reallocation_event_totals 的 PL/pgSQL 变量/列名歧义。
-- V313 原函数把局部变量命名为 reallocation_id，与 preplan_stock_entitlement_events
-- 的同名列冲突：PL/pgSQL 默认在歧义时报错，任何让料写入在延迟约束触发器（提交期）
-- 执行时都会以 "column reference "reallocation_id" is ambiguous" 失败——该缺陷由
-- 2026-08-23 全链 DB E2E 首次执行让料链路时暴露。
-- 修复：局部变量重命名为 active_reallocation_id，并把嵌入 SQL 的列引用全部显式限定，
-- 不依赖 variable_conflict 编译指示，语义与 V313 原意（按 header 聚合事件）完全一致。

CREATE OR REPLACE FUNCTION fn_validate_preplan_reallocation_event_totals()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    active_reallocation_id UUID;
    header preplan_material_reallocations%ROWTYPE;
    out_qty NUMERIC(18,4);
    in_qty NUMERIC(18,4);
    fulfilled_qty NUMERIC(18,4);
BEGIN
    IF TG_TABLE_NAME = 'preplan_material_reallocations' THEN
        active_reallocation_id := COALESCE(NEW.id, OLD.id);
    ELSE
        active_reallocation_id := COALESCE(NEW.reallocation_id, OLD.reallocation_id);
    END IF;
    IF active_reallocation_id IS NULL THEN RETURN NEW; END IF;
    SELECT * INTO header
    FROM preplan_material_reallocations WHERE id = active_reallocation_id;
    IF header.id IS NULL THEN RETURN NEW; END IF;
    SELECT COALESCE(SUM(event.qty), 0) INTO out_qty
    FROM preplan_stock_entitlement_events event
    WHERE event.reallocation_id = header.id
      AND event.event_type = 'REALLOCATE_OUT';
    SELECT COALESCE(SUM(event.qty), 0) INTO in_qty
    FROM preplan_stock_entitlement_events event
    WHERE event.reallocation_id = header.id
      AND event.event_type = 'REALLOCATE_IN';
    IF out_qty <> header.qty OR in_qty <> header.qty THEN
        RAISE EXCEPTION 'reallocation OUT/IN totals must equal header quantity'
            USING ERRCODE = '23514';
    END IF;
    SELECT COALESCE(SUM(CASE
               WHEN event.event_type IN (
                    'PRIORITY_IN', 'PRIORITY_SATISFIED_IN_PLACE')
               THEN event.qty
               WHEN event.event_type = 'RESTORE'
                    AND counter.event_type = 'PRIORITY_OUT'
               THEN -event.qty
               WHEN event.event_type = 'RELEASE'
                    AND counter.event_type = 'PRIORITY_SATISFIED_IN_PLACE'
               THEN -event.qty
               ELSE 0
           END), 0)
    INTO fulfilled_qty
    FROM preplan_stock_entitlement_events event
    LEFT JOIN preplan_stock_entitlement_events counter
      ON counter.id = event.counter_event_id
    WHERE event.reallocation_id = header.id;
    IF fulfilled_qty < 0
       OR fulfilled_qty > header.qty
       OR fulfilled_qty IS DISTINCT FROM header.priority_fulfilled_qty THEN
        RAISE EXCEPTION 'priority fulfilled quantity disagrees with events'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
