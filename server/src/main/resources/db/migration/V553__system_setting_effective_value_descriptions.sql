-- Clarify runtime behavior without changing any administrator-selected value.
UPDATE system_settings
SET description = '逗号分隔，仅支持 birthday(生日)、anniversary(入职纪念日)。每日北京时间 08:00:07 扫描；停发请关闭自动发布。'
WHERE key = 'celebration.auto_types';

UPDATE system_settings
SET description = '改密码时禁止复用最近 N 个历史密码；0 仅关闭历史回溯，仍禁止复用当前密码。'
WHERE key = 'password_history_size';
