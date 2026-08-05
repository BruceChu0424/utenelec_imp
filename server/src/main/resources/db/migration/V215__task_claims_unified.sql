-- =====================================================================
-- V215：统一任务软认领（泛化 ADR-021 §四 的 hr_task_claims，供审批/分解/履约等共享任务面复用）
-- 调研结论（ADR-023 / SAP/Dynamics/Camunda/Odoo 对照）：默认 show-as-locked——
-- 任务始终可见，认领者显示「XXX 处理中」，他人快捷操作禁用；不隐藏（隐藏抹去审计链、
-- 破坏休假接管与 maker-checker）。短租约（默认 30 分，按类型可配）+ 惰性过期 + 心跳续租 +
-- 管理员强制释放/接管。认领是 UX/防碰撞层；动作端点的 PESSIMISTIC_WRITE + 状态守卫仍是完整性底线。
-- 与既有 hr_task_claims 并存：HR 域继续用 hr_task_claims（V213），新共享面接入统一 task_claims。
-- =====================================================================

CREATE TABLE task_claims (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    target_type     TEXT NOT NULL,                -- EXPENSE_APPROVE / PURCHASE_DECOMPOSE / SALES_ORDER_APPROVE / FULFILLMENT_TASK ...
    target_key      TEXT NOT NULL,                -- 目标对象规范键（通常是单据/明细 UUID 字符串）
    claimed_by      UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    claimed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    lease_until     TIMESTAMPTZ NOT NULL,         -- 租约到期；过期视为自动释放（读取时惰性判定，无需定时任务）
    last_heartbeat  TIMESTAMPTZ,                  -- 可选心跳；启用时由前端定期续租
    released_at     TIMESTAMPTZ,                  -- 释放/被接管/过期回收时间；NULL = 仍占用（在租约内有效）
    release_reason  TEXT,                         -- manual / takeover / expired / admin_force_release / completed
    released_by     UUID REFERENCES employees(id),
    remark          TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      UUID,
    updated_by      UUID
);

-- 同一目标同一时间只允许一条未释放认领（并发两认领只一笔成功，靠此部分唯一索引仲裁）
CREATE UNIQUE INDEX uq_task_claim_active
    ON task_claims (target_type, target_key)
    WHERE released_at IS NULL;
CREATE INDEX idx_task_claim_claimer ON task_claims (claimed_by) WHERE released_at IS NULL;
CREATE INDEX idx_task_claim_lease   ON task_claims (lease_until) WHERE released_at IS NULL;

COMMENT ON TABLE task_claims IS
'统一任务软认领：target_type+target_key 唯一；默认显示「XXX 处理中」不隐藏；短租约+惰性过期；管理员可强制释放/接管（ADR-023）';

-- 通用审计触发器（fn_audit 见 V05；与 hr_task_claims 同范式）
DROP TRIGGER IF EXISTS trg_audit_task_claims ON task_claims;
CREATE TRIGGER trg_audit_task_claims
    AFTER INSERT OR UPDATE OR DELETE ON task_claims
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
