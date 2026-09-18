-- V600: 庆典通知（生日/入职周年祝福）改为默认不自动发送。
--
-- 背景：V224 种子 celebration.auto_enabled = true，每天 08:00（北京时间）
-- CelebrationScheduler 自动扫描在职员工生日/入职纪念日并直接发布祝福卡，
-- 人事全程无感、也无法拦。用户口径（2026-09-17）：祝福应由人事自己发；
-- 页面上提供「自动发送」开关，打开了才自动发。
--
-- 落地三件套：
--   1) 本迁移：存量库把已存的 true 翻为 false（有意的策略变更而非遗漏；
--      幂等——已是 false 不动，人事之后想恢复代发由新端点写回 true）；
--   2) 代码默认值同步改 false（CelebrationScheduler / NoticeService 读取处）；
--   3) 新端点 PUT /api/notices/celebration/auto（notice:publish，与手动批量
--      祝福同级）供 HR 任务中心页面开关翻转；系统设置管理页的原
--      PUT /api/notices/celebration/settings（authorization:manage + 二次密码）保留。
--
-- 注意：设置行 updated_by 不动（迁移非人工操作），updated_at 由触发器/默认维护。

UPDATE system_settings
   SET value = 'false',
       updated_at = now()
 WHERE key = 'celebration.auto_enabled'
   AND value = 'true';

-- 描述同步新口径（管理后台系统设置页展示）。
UPDATE system_settings
   SET description = '开启后每日 08:00（北京时间）自动扫描在职员工生日/入职纪念日并发布庆典通知；默认关闭，由人事在 HR 任务中心手动送祝福，也可在该页打开「自动发送」',
       updated_at = now()
 WHERE key = 'celebration.auto_enabled';
