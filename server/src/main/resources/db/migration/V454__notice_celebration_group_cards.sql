-- =====================================================================
-- V454：庆典祝福聚合卡（每日每类一张）+ notice_celebration_subjects 主角表
-- =====================================================================
-- 背景：V224 的庆典通知是「一人一卡」——5 位同事同一天生日就发 5 张祝福卡，
--   通知列表被刷屏、祝福互动分散。本次改为：自动调度（CelebrationScheduler）
--   与 HR 任务中心「一键全部送祝福」每天每类型只发一张聚合卡，卡内列出全部主角；
--   入职周年各人年数不同，主角各自带 event_label（张三 入职5周年、李四 入职10周年）。
-- 结构：
--   * 新表 notice_celebration_subjects：庆典卡主角名单快照
--     （employee_id 可空引用 + 姓名快照 + 各自事件标签）。
--     去重 / 「我的今日庆典」/ HR 已祝福标记一律按本表 (employee,type,当年) 口径，
--     与单人卡统一；单人卡（含手动新婚/新生儿）发布时同样写一行主角快照。
--   * 存量单人卡回填主角行，老数据展示与幂等口径不受影响。
--   * notices.subject_employee_id / subject_name / event_label 保留：
--     单人卡继续写（前端兜底展示）；聚合卡 subject_employee_id=NULL，
--     subject_name 写「张三、李四等 N 人」摘要，逐人标签见主角表。
--   * V224 的 idx_notices_subject_type 随去重口径迁到主角表后不再命中，一并删除；
--     主角表自带 (notice_id) 局部唯一 + (employee_id) 查询索引。
-- 审计口径：本表是通知域发布机制的姓名快照（与 notice_blessings 同类），
--   按 V424 降噪口径不挂审计触发器；人工发布动作已有显式审计事件
--   （notice_publish / notice_celebration_batch_publish）。
-- =====================================================================

CREATE TABLE notice_celebration_subjects (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    notice_id     UUID NOT NULL REFERENCES notices(id) ON DELETE CASCADE,
    employee_id   UUID NULL REFERENCES employees(id) ON DELETE SET NULL,
    employee_name VARCHAR(100) NOT NULL,
    event_label   VARCHAR(100) NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    UUID,
    updated_by    UUID
);

-- 一张卡内同一员工只出现一次（employee_id 置 NULL 的历史孤儿不参与唯一性）
CREATE UNIQUE INDEX uq_notice_celebration_subjects
    ON notice_celebration_subjects(notice_id, employee_id)
    WHERE employee_id IS NOT NULL;
CREATE INDEX idx_notice_celebration_subjects_notice
    ON notice_celebration_subjects(notice_id);
-- 幂等去重 / 我的今日庆典 / HR 已祝福标记都按员工维度查本表
CREATE INDEX idx_notice_celebration_subjects_employee
    ON notice_celebration_subjects(employee_id);

COMMENT ON TABLE notice_celebration_subjects IS
    '庆典通知主角名单快照（聚合卡多主角 / 单人卡一行；发布后改名不回溯）';
COMMENT ON COLUMN notice_celebration_subjects.employee_id IS
    '主角员工 ID；员工被物理删除时置 NULL（姓名快照保留）';
COMMENT ON COLUMN notice_celebration_subjects.event_label IS
    '该主角的事件标签快照（如 生日快乐 / 入职5周年）';

-- 存量单人卡回填：每张有 subject_employee_id 的庆典通知补一行主角快照
INSERT INTO notice_celebration_subjects (
    notice_id, employee_id, employee_name, event_label)
SELECT n.id,
       n.subject_employee_id,
       COALESCE(NULLIF(btrim(n.subject_name), ''), '（未知）'),
       COALESCE(NULLIF(btrim(n.event_label), ''), '')
FROM notices n
WHERE n.subject_employee_id IS NOT NULL
  AND n.type IN ('birthday', 'anniversary', 'wedding', 'newborn')
  AND NOT EXISTS (
      SELECT 1 FROM notice_celebration_subjects s
      WHERE s.notice_id = n.id
        AND s.employee_id = n.subject_employee_id
  );

-- 去重口径迁到主角表后，V224 的旧索引不再命中任何查询
DROP INDEX IF EXISTS idx_notices_subject_type;
