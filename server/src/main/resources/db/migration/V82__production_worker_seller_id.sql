-- 生产计划单头：跟单员 / 生产工从 legacy 文本升级为关联 employees 的 UUID（无 FK，范式同 maker_id）。
-- 老库 Seller / WorkerID varchar(250) 原样留在 seller_name / worker_name（报表 facet / 冻结名仍可用）；
-- 新列承接前端员工选择器所选的真 id。历史单 id 留空（B_Worker 与 employees 无 legacy_id 对齐，
-- 待后续 worker_legacy_map 回填）。新建单由编辑页 UtenEmployeePicker 写入。
ALTER TABLE production_plans ADD COLUMN seller_id UUID;
ALTER TABLE production_plans ADD COLUMN worker_id UUID;
