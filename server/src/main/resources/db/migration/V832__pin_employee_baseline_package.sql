-- =====================================================================
-- V832：员工基础包钉死护栏（2026-10-09 计划部弹窗熄火事故的根因修复）
-- =====================================================================
-- 事故：全员基础包在管理页按「期望的完整集合」整体保存，移出一律允许。2026-10-09 01:29
--   超管一次保存把当时包内 6 个码全部移出（audit 89403-89408）。notice:read 一旦离开
--   基础包，全体非超管用户同时失去三样东西：
--     ① 前端到达轮询/登录检查门的挂载资格（AppUser.can('notice:read')）；
--     ② /api/notices/** 的访问权；
--     ③ ChainNoticeService 全部发卡池的接收资格（发卡池都要求 notice:read）。
--   销售→财务确认→计划部「新订单待物料分析」弹窗整链静默熄火，outbox 事件仍标记投递
--   成功、无任何报错；财务侧弹窗"看似正常"只是因为操作者是超管（有效权限恒为全量）。
--   事后手工修复也只恢复了 V831 断言卡住的 3 个自助码，漏掉 notice:read 与
--   profile:edit:self。
-- 决策（ADR-170）：V677 平移的员工基础包 5 码是通知与员工自助服务的「体系准入」权限，
--   钉死在全员基础包（permissions.baseline_pinned）：
--     · 管理页不可移出——服务层差量保存拒绝 + 数据库 CHECK 兜底；
--     · 只有数据库迁移能解除钉死或调整钉死名单（沿 V679/V821 用迁移调整基础包成员的先例）；
--     · 个人收回（user_permission_overrides revoke）仍最高优先，个别滥用者仍可按人收回。
-- =====================================================================

ALTER TABLE permissions
    ADD COLUMN baseline_pinned BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE permissions
SET baseline = TRUE,
    baseline_pinned = TRUE
WHERE code IN (
    'notice:read',
    'profile:edit:self',
    'expense:apply',
    'suggestion:submit',
    'payroll:view:self'
);

COMMENT ON COLUMN permissions.baseline_pinned IS
    '基础包钉死(V832/ADR-170)：TRUE 表示体系准入码锁定在全员基础包，管理页不可移出，只有迁移能解除；钉死码必须同时在基础包里';

ALTER TABLE permissions
    ADD CONSTRAINT permissions_baseline_pinned_chk
        CHECK (NOT baseline_pinned OR baseline);

DO $$
BEGIN
    IF (SELECT count(*) FROM permissions WHERE baseline_pinned) <> 5 THEN
        RAISE EXCEPTION 'V832 the five employee baseline codes must be pinned';
    END IF;
    IF (SELECT count(*) FROM permissions
        WHERE code IN ('notice:read', 'profile:edit:self', 'expense:apply',
                       'suggestion:submit', 'payroll:view:self')
          AND NOT (baseline AND baseline_pinned)) <> 0 THEN
        RAISE EXCEPTION 'V832 every pinned employee code must sit in the baseline';
    END IF;
END;
$$;
