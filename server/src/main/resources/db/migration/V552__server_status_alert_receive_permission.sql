-- 服务器状态告警接收权（2026-09-11）。
--
-- 背景：ServerStatusProbe 早就会算出磁盘 80%/90% 这类告警，但它们**只塞进页面返回值**，
-- 没有任何地方推给人。结果是附件卷可以从 1% 一路涨到 91%，只要没人主动点开
-- 「工作台 → 服务器状态」就无人知晓。现在由 ServerStatusAlertScheduler 定期采样并
-- 推送站内通知，接收人由本权限码控制——与「谁能看这个页面」（server_status:view）
-- 分开授，因为「能看」和「该被半夜吵醒」不是同一件事。
INSERT INTO permissions(code,name,module,category,sort_order,action_type,description,
                        active,assignable,bulk_assignable,sensitivity)
VALUES ('server_status:alert:receive','接收服务器状态告警','系统管理','服务器状态',247,'VIEW',
        '磁盘/内存/数据库/备份等指标越过警告或危急阈值时收到站内通知；恢复后另发一条。'
        '仅决定谁被通知，不额外授予任何查看或维护能力',
        TRUE,TRUE,TRUE,'NORMAL')
ON CONFLICT (code) DO UPDATE SET name=EXCLUDED.name,module=EXCLUDED.module,
    category=EXCLUDED.category,sort_order=EXCLUDED.sort_order,action_type=EXCLUDED.action_type,
    description=EXCLUDED.description,active=EXCLUDED.active,assignable=EXCLUDED.assignable,
    bulk_assignable=EXCLUDED.bulk_assignable,sensitivity=EXCLUDED.sensitivity;

-- 默认授给「已经能看服务器状态」的那些部门：能看的人本来就该第一时间知道它坏了。
-- 之后谁收谁不收由权限页自由调整（本条只建默认，不锁死）。
INSERT INTO department_permissions(department_id, permission_id)
SELECT existing.department_id, target.id
FROM department_permissions existing
JOIN permissions source ON source.id = existing.permission_id AND source.code = 'server_status:view'
CROSS JOIN permissions target
WHERE target.code = 'server_status:alert:receive'
ON CONFLICT DO NOTHING;
