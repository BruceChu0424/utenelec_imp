-- V810 (临时号, 合并时按 main 迁移头重排): 员工资料核对计划(ADR-160)。
--
-- 背景: 证件核对页多选员工后, 服务端为每人生成一行核对计划: 证件号的修复建议(旧值/新值/候选值, 均为
-- pgp 密文)存进 employee_reconcile_plan_items, 人事确认后逐人调既有 changeIdentity 更正; 计划与更正回执
-- 本身就是操作记录。计划有效期最多 24 小时, 过期未执行的由 ReconcilePlanHousekeeping 定时关闭并清掉
-- 未执行项的密文; 已执行项(更正记录)长期保留。
--
-- 段落: 1 四张表  2 清空业务数据登记  3 自检
--
-- 为什么 PRESERVE: 这几张核对记录表与 profile_change_requests / employment_history 同类——业务清空时
-- 员工档案保留, 更正记录也应一并保留; 表里的值列只有密文或统计数字, 保留不会泄漏证件号。
--
-- 为什么不挂行级审计(登记审计 NONE): 值列为密文或统计, 整行复制只会留下密文噪声; 计划的创建、确认、
-- 逐人更正与关闭都由显式业务审计事件记录。

-- ---------------------------------------------------------------------
-- 1. 四张表: 计划 / 逐人计划行 / 修复建议项(密文) / 更正回执
-- ---------------------------------------------------------------------
CREATE TABLE employee_reconcile_plans (
    id                uuid PRIMARY KEY,
    source            varchar(12) NOT NULL CHECK (source IN ('ID_REPAIR')),
    origin            varchar(8)  NOT NULL CHECK (origin IN ('PAGE')),
    actor_user_id     uuid NOT NULL REFERENCES users(id),
    actor_employee_id uuid REFERENCES employees(id),
    counts            jsonb NOT NULL DEFAULT '{}'::jsonb,
    status            varchar(12) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPLYING','CLOSED')),
    closed_reason     varchar(12) CHECK (closed_reason IN ('EXPIRED','DISCARDED')),
    version           integer NOT NULL DEFAULT 1,
    applying_until    timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    expires_at        timestamptz NOT NULL,
    last_applied_at   timestamptz,
    purged_at         timestamptz,
    CONSTRAINT ck_erp_expiry   CHECK (expires_at > created_at AND expires_at <= created_at + interval '24 hours'),
    CONSTRAINT ck_erp_closed   CHECK ((status = 'CLOSED') = (closed_reason IS NOT NULL)),
    CONSTRAINT ck_erp_applying CHECK ((status = 'APPLYING') = (applying_until IS NOT NULL)),
    CONSTRAINT ck_erp_counts   CHECK (octet_length(counts::text) <= 4096)
);
CREATE INDEX idx_erp_actor_created ON employee_reconcile_plans (actor_user_id, created_at DESC);
CREATE INDEX idx_erp_open_expiry   ON employee_reconcile_plans (expires_at) WHERE status <> 'CLOSED';
COMMENT ON TABLE employee_reconcile_plans IS
    'V810(ADR-160): 员工资料核对计划(每人一张, 由证件核对页多选生成). 不挂行级审计(登记审计 NONE): 值列为密文或统计, 操作记录走显式业务审计事件';

CREATE TABLE employee_reconcile_plan_rows (
    plan_id          uuid NOT NULL REFERENCES employee_reconcile_plans(id),
    row_no           integer NOT NULL CHECK (row_no > 0),
    employee_id      uuid NOT NULL REFERENCES employees(id),
    employee_version integer NOT NULL,
    kind             varchar(8) NOT NULL CHECK (kind IN ('UPDATE','INFO','SAME')),
    notice_codes     varchar(48)[] NOT NULL DEFAULT '{}',
    result           varchar(8) CHECK (result IN ('APPLIED','PARTIAL','SKIPPED','FAILED')),
    PRIMARY KEY (plan_id, row_no)
);
CREATE INDEX idx_erpr_employee ON employee_reconcile_plan_rows (employee_id);
COMMENT ON TABLE employee_reconcile_plan_rows IS
    'V810(ADR-160): 核对计划的逐人行(计划内序号 + 生成时的员工版本). 不挂行级审计(登记审计 NONE): 值列为密文或统计, 操作记录走显式业务审计事件';

CREATE TABLE employee_reconcile_applies (
    id            uuid PRIMARY KEY,
    plan_id       uuid NOT NULL REFERENCES employee_reconcile_plans(id),
    round_no      smallint NOT NULL,
    request_id    varchar(64) NOT NULL,
    actor_user_id uuid NOT NULL REFERENCES users(id),
    status        varchar(12) NOT NULL DEFAULT 'RUNNING' CHECK (status IN ('RUNNING','FINISHED','INTERRUPTED')),
    counts        jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (octet_length(counts::text) <= 4096),
    result        jsonb CHECK (result IS NULL OR result::text !~ '[0-9]{6,}'),
    started_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz,
    UNIQUE (plan_id, request_id),
    UNIQUE (plan_id, round_no)
);
COMMENT ON TABLE employee_reconcile_applies IS
    'V810(ADR-160): 核对计划的一轮更正回执(同请求幂等, 同计划轮次唯一). 不挂行级审计(登记审计 NONE): 值列为密文或统计, 操作记录走显式业务审计事件';

CREATE TABLE employee_reconcile_plan_items (
    plan_id           uuid NOT NULL,
    row_no            integer NOT NULL,
    item_no           smallint NOT NULL CHECK (item_no > 0),
    field_code        varchar(24) NOT NULL CHECK (field_code IN ('idNumber')),
    write_path        varchar(16) NOT NULL CHECK (write_path IN ('CHANGE_IDENTITY')),
    required_permissions varchar(48)[] NOT NULL DEFAULT '{employee:pii:edit}',
    old_value_enc     text,
    new_value_enc     text,
    candidates_enc    text,
    diff_positions    smallint[] NOT NULL DEFAULT '{}',
    suspect_positions smallint[] NOT NULL DEFAULT '{}',
    basis_code        varchar(24) NOT NULL,
    tier              varchar(8) NOT NULL CHECK (tier IN ('HIGH','MEDIUM','MANUAL','NONE')),
    probability       numeric(4,3) CHECK (probability IS NULL OR probability >= 0 AND probability <= 1),
    preselected       boolean NOT NULL DEFAULT false,
    note_codes        varchar(48)[] NOT NULL DEFAULT '{}',
    applied_origin    varchar(12) CHECK (applied_origin IN ('SUGGESTED','CANDIDATE','EDITED')),
    outcome           varchar(8) CHECK (outcome IN ('APPLIED','SKIPPED','FAILED')),
    outcome_code      varchar(48),
    outcome_message   varchar(240),
    apply_id          uuid REFERENCES employee_reconcile_applies(id),
    applied_at        timestamptz,
    PRIMARY KEY (plan_id, row_no, item_no),
    FOREIGN KEY (plan_id, row_no) REFERENCES employee_reconcile_plan_rows (plan_id, row_no),
    CONSTRAINT ck_erpi_outcome   CHECK ((outcome IS NULL) = (applied_at IS NULL) AND (outcome IS NULL) = (apply_id IS NULL)),
    CONSTRAINT ck_erpi_no_digits CHECK (outcome_message IS NULL OR outcome_message !~ '[0-9]{6,}')
);
COMMENT ON TABLE employee_reconcile_plan_items IS
    'V810(ADR-160): 核对计划逐人行的修复建议项(证件号旧值/新值/候选值均为 pgp 密文, 位置与理由码非敏感). 不挂行级审计(登记审计 NONE): 值列为密文或统计, 操作记录走显式业务审计事件';

-- ---------------------------------------------------------------------
-- 2. 清空业务数据: 核对记录与 profile_change_requests / employment_history 同类,
--    员工档案保留时更正记录一并保留(V809 同款锚点补丁, needle 单行无换行)
-- ---------------------------------------------------------------------
DO $reset_policy$
DECLARE
    definition TEXT;
    anchor TEXT := '(''subcontract_application_kit_notice_marks'', ''CLEAR''),';
BEGIN
    SELECT replace(pg_get_functiondef('business_data_reset()'::regprocedure), chr(13), '') INTO definition;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1
       OR position('employee_reconcile_plans' IN definition) > 0
       OR position('employee_reconcile_plan_rows' IN definition) > 0
       OR position('employee_reconcile_plan_items' IN definition) > 0
       OR position('employee_reconcile_applies' IN definition) > 0 THEN
        RAISE EXCEPTION 'V810 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition, anchor,
        anchor || E'\n            (''employee_reconcile_plans'', ''PRESERVE''),'
                  || E'\n            (''employee_reconcile_plan_rows'', ''PRESERVE''),'
                  || E'\n            (''employee_reconcile_plan_items'', ''PRESERVE''),'
                  || E'\n            (''employee_reconcile_applies'', ''PRESERVE''),');
END;
$reset_policy$;

-- ---------------------------------------------------------------------
-- 3. 自检
-- ---------------------------------------------------------------------
DO $v810_self_check$
DECLARE
    definition TEXT;
BEGIN
    SELECT replace(pg_get_functiondef('business_data_reset()'::regprocedure), chr(13), '') INTO definition;
    IF position('(''employee_reconcile_plans'', ''PRESERVE'')' IN definition) = 0
       OR position('(''employee_reconcile_plan_rows'', ''PRESERVE'')' IN definition) = 0
       OR position('(''employee_reconcile_plan_items'', ''PRESERVE'')' IN definition) = 0
       OR position('(''employee_reconcile_applies'', ''PRESERVE'')' IN definition) = 0 THEN
        RAISE EXCEPTION 'V810 business_data_reset must preserve the employee reconcile tables';
    END IF;
    IF to_regclass('employee_reconcile_plans') IS NULL
       OR to_regclass('employee_reconcile_plan_rows') IS NULL
       OR to_regclass('employee_reconcile_plan_items') IS NULL
       OR to_regclass('employee_reconcile_applies') IS NULL THEN
        RAISE EXCEPTION 'V810 reconcile tables missing';
    END IF;
END;
$v810_self_check$;
