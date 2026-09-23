-- V681 系统设置单一登记 (ADR-110; audit-retention-settings-09/11/12)
--
-- 背景: 设置项的键、类型、默认值、取值范围、说明、是否公开分散在迁移、服务、各调用方和前端四处,
-- 默认值与库值不一致 (jwt_access_ttl_minutes 代码默认 15 / 种子 480 / 回改 15; refresh 7 / 1),
-- impersonation_window_minutes 代码在读却没有数据行、界面改不了。
--
-- 新口径: Java 枚举 SystemSettingKey 是唯一登记 (键/类型/默认/最小/最大/分组/是否公开/名称/单位/
-- 排序/说明)。本表只存「当前值」与最后修改人/时间, 行集合必须与枚举一致
-- (SystemSettingRegistryContractTest 在全新库上断言行集合与种子默认值)。
--
-- 本迁移:
--   1) 删除表里的元数据列 (value_type/category/label/description/unit/sort_order), 它们改由枚举提供;
--   2) 补齐枚举新登记项的行 (值=登记默认值): 切换人窗口、密码最短长度、临时密码有效期、
--      三个业务预警天数、待办角标刷新间隔;
--   3) 把已存值收进新登记的范围 (登录令牌有效期 5~1440 分钟、登录保持时长 1~30 天),
--      越界值按最近边界落库, 不改变其它管理员已选值。

ALTER TABLE system_settings
    DROP COLUMN value_type,
    DROP COLUMN category,
    DROP COLUMN label,
    DROP COLUMN description,
    DROP COLUMN unit,
    DROP COLUMN sort_order;

COMMENT ON TABLE system_settings IS
    '系统设置当前值; 键/类型/默认/范围/名称/说明只登记在 SystemSettingKey 枚举 (ADR-110)';

INSERT INTO system_settings (key, value) VALUES
    ('impersonation_window_minutes', '15'),
    ('password_min_length', '8'),
    ('temp_password_ttl_hours', '72'),
    ('delivery_due_warning_days', '3'),
    ('reservation_hold_grace_days', '7'),
    ('subcontract_return_due_days', '3'),
    ('badge_poll_seconds', '60')
ON CONFLICT (key) DO NOTHING;

UPDATE system_settings
SET value = CASE WHEN value::bigint < 5 THEN '5' ELSE '1440' END
WHERE key = 'jwt_access_ttl_minutes'
  AND value ~ '^[0-9]+$'
  AND (value::bigint < 5 OR value::bigint > 1440);

UPDATE system_settings
SET value = CASE WHEN value::bigint < 1 THEN '1' ELSE '30' END
WHERE key = 'jwt_refresh_ttl_days'
  AND value ~ '^[0-9]+$'
  AND (value::bigint < 1 OR value::bigint > 30);
