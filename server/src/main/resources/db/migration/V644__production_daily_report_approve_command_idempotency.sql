-- V644: 审核生产日报的幂等键。
--
-- 审核是整条报工链里最重的一次写(实测 4 行车间直送 15.094 秒、约 350 行落账)。
-- 浏览器把连接掐断时事务往往已经提交，用户再点一次只能撞上状态闸门，
-- 分不清「刚才其实成功了」和「真的失败了」。V409 的创建命令账本已经解决了同一类问题，
-- 这里把它从「创建命令账本」升级为「日报命令账本」：同一张表、同一把
-- (操作者, 幂等键) 唯一键，只多一列区分命令种类。不新增表，所以清库策略、
-- 审计覆盖与 fixture 漂移守卫都不需要跟着改。

ALTER TABLE production_daily_report_commands
    ADD COLUMN command_kind VARCHAR(16) NOT NULL DEFAULT 'CREATE',
    ADD CONSTRAINT production_daily_report_command_kind_chk
        CHECK (command_kind IN ('CREATE', 'APPROVE', 'REVERSE'));

-- 一张日报最多一条 CREATE、一条 APPROVE、一条 REVERSE。
-- 原 UNIQUE(report_id) 的「一张日报只能被创建一次」不变，只是把命令种类并进键里。
ALTER TABLE production_daily_report_commands
    DROP CONSTRAINT uq_production_daily_report_command_report,
    ADD CONSTRAINT uq_production_daily_report_command_report_kind
        UNIQUE (report_id, command_kind);

COMMENT ON TABLE production_daily_report_commands IS
    'Append-only daily-report command ledger. One actor plus key binds permanently to one report and one command kind.';
COMMENT ON COLUMN production_daily_report_commands.command_kind IS
    'Which command this row binds: CREATE binds one report, APPROVE binds one approval, REVERSE is reserved for the symmetric reversal.';
