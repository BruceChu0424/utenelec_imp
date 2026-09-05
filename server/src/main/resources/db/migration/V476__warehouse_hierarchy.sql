-- ========== V476 仓库主/子层级：warehouses.parent_id 自引用 + 存量层级种子 ==========
--
-- 业务背景：看盘/查询页（即时库存等）需要「主仓库 = 全部子仓聚合」的视角——例如
-- 仓库（14年版）设为主仓库，其余仓（成品仓库/不良仓/五金仓库/轨道车间）挂为其子仓；
-- 查询选父仓 = 父仓自身 + 全部后代聚合（服务端展开，见 WarehouseScopeService）。
-- 老库 B_Storage 是扁平表（ParentID 全 0），层级属于新库运营建模，不在老库迁移范围。
--
-- 约定：
-- - parent_id 为空 = 独立顶层仓；
-- - 单据/收发存等运营场景仍只允许落到具体（叶子）仓，父仓仅作查询聚合与下拉分组；
-- - 种子只做一次性数据整理：仓库（14年版）（code='001'）设为主仓库，其余未软删仓
--   挂为其子仓；今后新增仓库默认独立顶层，可在仓库资料里维护上级（服务端防环）。

ALTER TABLE warehouses
    ADD COLUMN parent_id uuid REFERENCES warehouses(id) ON DELETE RESTRICT;

CREATE INDEX idx_warehouses_parent ON warehouses(parent_id) WHERE parent_id IS NOT NULL;

-- 存量层级种子：主仓自身与其余仓挂接（主仓无 parent、已软删仓不动；root 缺失时为空更新）。
UPDATE warehouses AS w
   SET parent_id = root.id
  FROM (SELECT id FROM warehouses WHERE code = '001' AND is_deleted = false) root
 WHERE w.parent_id IS NULL
   AND w.is_deleted = false
   AND w.id <> root.id;
