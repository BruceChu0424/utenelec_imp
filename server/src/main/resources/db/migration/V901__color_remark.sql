ALTER TABLE colors ADD COLUMN remark text;

COMMENT ON COLUMN colors.remark IS '颜色备注；日常资料可维护，旧记录默认为空';
