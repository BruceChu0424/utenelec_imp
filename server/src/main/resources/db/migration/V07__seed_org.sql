-- 种子组织树：中山市优腾电器有限公司（含保安部）
-- path 由 trg_dept_path 触发器自动计算，这里只填 code/name/level/parent_id/sort_order
-- 父子关系用 code 子查询挂接

-- L1 公司
INSERT INTO departments (code, name, level, sort_order) VALUES
    ('UTEN', '中山市优腾电器有限公司', '公司', 0);

-- L2 决策层
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT 'GM', '总经办', '决策层', p.id, 1 FROM departments p WHERE p.code='UTEN';

-- L3 管理中心（3 个并行）
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT 'MFG_CENTER', '制造与研发管理中心', '管理中心', p.id, 1 FROM departments p WHERE p.code='GM';
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT 'MKT_CENTER', '营销与新媒体管理中心', '管理中心', p.id, 2 FROM departments p WHERE p.code='GM';
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT 'FIN_CENTER', '财税及行政管理中心', '管理中心', p.id, 3 FROM departments p WHERE p.code='GM';

-- ===== 制造与研发管理中心 =====
-- 一级部门
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT 'DEPT_PROD', '生产部', '一级部门', p.id, 1 FROM departments p WHERE p.code='MFG_CENTER';
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT 'DEPT_ENG',  '工程研发部', '一级部门', p.id, 2 FROM departments p WHERE p.code='MFG_CENTER';
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT 'DEPT_PMC',  'PMC运营部', '一级部门', p.id, 3 FROM departments p WHERE p.code='MFG_CENTER';
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT 'DEPT_QA',   '品质管理部', '一级部门', p.id, 4 FROM departments p WHERE p.code='MFG_CENTER';

-- 生产部 → 6 车间
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT v.code, v.name, '二级班组', p.id, v.sort FROM departments p
CROSS JOIN (VALUES
    ('WS_ZHUSU','注塑车间',1),
    ('WS_WJTZ','五金铜柱车间',2),
    ('WS_JXJG','机械加工车间',3),
    ('WS_ZHUANG','装配车间',4),
    ('WS_ESD','ESD电子智造车间',5),
    ('WS_DLGD','电力轨道装配车间',6)
) AS v(code,name,sort)
WHERE p.code='DEPT_PROD';

-- 工程研发部 → 2 工程组
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT v.code, v.name, '二级班组', p.id, v.sort FROM departments p
CROSS JOIN (VALUES
    ('GRP_PE','PE工程组',1),
    ('GRP_RD','研发工程组',2)
) AS v(code,name,sort)
WHERE p.code='DEPT_ENG';

-- PMC运营部 → 4 子部门
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT v.code, v.name, '二级班组', p.id, v.sort FROM departments p
CROSS JOIN (VALUES
    ('SUB_PLAN','计划部',1),
    ('SUB_PURCHASE','采购部',2),
    ('SUB_WL','物料控制部',3),
    ('SUB_WH','仓储部',4)
) AS v(code,name,sort)
WHERE p.code='DEPT_PMC';

-- 品质管理部 → 3 单元
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT v.code, v.name, '二级班组', p.id, v.sort FROM departments p
CROSS JOIN (VALUES
    ('QA_TEST','检验检测室',1),
    ('QA_CERT','质量与认证室',2),
    ('QA_OUT','外协工作组',3)
) AS v(code,name,sort)
WHERE p.code='DEPT_QA';

-- ===== 营销与新媒体管理中心 =====
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT 'DEPT_SALES',    '综合营销部',   '一级部门', p.id, 1 FROM departments p WHERE p.code='MKT_CENTER';
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT 'DEPT_NEWMEDIA', '新媒体事业部', '一级部门', p.id, 2 FROM departments p WHERE p.code='MKT_CENTER';
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT 'DEPT_RAIL',     '轨道事业部',   '一级部门', p.id, 3 FROM departments p WHERE p.code='MKT_CENTER';

-- 综合营销部 → 销售 1~4 组
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT v.code, v.name, '二级班组', p.id, v.sort FROM departments p
CROSS JOIN (VALUES
    ('SALE_G1','销售一组',1),
    ('SALE_G2','销售二组',2),
    ('SALE_G3','销售三组',3),
    ('SALE_G4','销售四组',4)
) AS v(code,name,sort)
WHERE p.code='DEPT_SALES';

-- 轨道事业部 → 2 销售组
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT v.code, v.name, '二级班组', p.id, v.sort FROM departments p
CROSS JOIN (VALUES
    ('RAIL_MUDUO','慕朵轨道销售组',1),
    ('RAIL_ZHIQIAN','智谦轨道销售组',2)
) AS v(code,name,sort)
WHERE p.code='DEPT_RAIL';

-- ===== 财税及行政管理中心 =====
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT 'DEPT_FIN', '财税部',           '一级部门', p.id, 1 FROM departments p WHERE p.code='FIN_CENTER';
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT 'DEPT_HR',  '行政与人力资源部', '一级部门', p.id, 2 FROM departments p WHERE p.code='FIN_CENTER';
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT 'DEPT_SECURITY', '保安部',      '一级部门', p.id, 3 FROM departments p WHERE p.code='FIN_CENTER';

-- 行政与人力资源部 → 3 组
INSERT INTO departments (code, name, level, parent_id, sort_order)
SELECT v.code, v.name, '二级班组', p.id, v.sort FROM departments p
CROSS JOIN (VALUES
    ('HR_HR','人力资源组',1),
    ('HR_UTEN','优腾行政组',2),
    ('HR_PARK','园区行政组',3)
) AS v(code,name,sort)
WHERE p.code='DEPT_HR';
