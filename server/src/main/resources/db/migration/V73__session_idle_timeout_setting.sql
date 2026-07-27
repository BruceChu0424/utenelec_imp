-- V73：会话空闲超时阈值（系统设置新增项，配合前端滑动会话超时）
-- --------------------------------------------------------------------------------
-- 场景：用户一直在用系统（有操作）→ 不超时；停止操作 N 分钟 → 前端弹窗提示后自动登出
-- （「您已N分钟没有使用系统，根据优腾系统安全法，将自动退出系统，您需要重新登录」）。
--
-- 实现：阈值由前端 IdleTimeoutController 读取（GET /api/settings/public），前端全局 Listener
-- 监听用户活动续期，超时触发弹窗 + logout（清 access+refresh 强制重认证）。后端 token 机制不变
-- （access/refresh TTL 仍由 jwt_*_ttl_* 控制）；本阈值是「前端强制空闲登出」的边界。

INSERT INTO system_settings (key, value, value_type, category, label, description, unit, sort_order) VALUES
    ('session_idle_timeout_minutes', '30', 'int', 'security', '会话空闲超时',
     '无操作多少分钟后自动退出登录（滑动：有操作则续期，仅前端触发登出）', '分钟', 60)
ON CONFLICT (key) DO NOTHING;
