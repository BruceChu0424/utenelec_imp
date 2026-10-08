-- =====================================================================
-- V831：常用模块权限分组（工作台「常用功能」卡的自助权限入口，ADR-168）
-- =====================================================================
-- 背景：工作台「常用功能」组的四张自助卡（我的访客/工资条/我的报销/意见箱）对应的
--   权限码原先散在「人事行政」模块的访客/工资条/报销/意见箱子类里，管理员要翻找
--   才能控制谁看得到这些卡。本迁移把四个自助码归入新一级模块「常用模块」，
--   子类名与工作台卡片同名、sort_order 按卡片顺序固定，权限管理页三段视图
--   （按员工/按部门/全员基础包）里都是第一组——勾选/收回即控制卡片显隐。
--   卡片显隐本就走路由守卫（requiredAnyPermFor，单一数据源不变），不新增任何码。
-- 口径：
--   1) 只挪目录归类（module/category/sort_order），不动 code/name/description/
--      grant_policy/baseline/授权行——收发权限的行为与 V677/V679 完全一致；
--   2) 管理码不动：payroll:view:all/generate/review/publish/export、expense:approve/
--      pay/settings、visitor:approve/check_in/verify/blacklist、suggestion:reply
--      仍在「人事行政」各自子类；
--   3) 工作台「基础资料」卡不设单一码：卡片与 hub 显隐仍由「基础资料」模块里
--      各主档 view 码的并集控制（hub 守卫=子卡并集，ADR-109 §3.7），
--      权限管理页的「基础资料」模块就是它的控制面；
--   4) module 归类的权威仍在迁移链上（V228 定的约定：后续改动在各自迁移里直接写）。
-- =====================================================================

UPDATE permissions
SET module = '常用模块', category = '我的访客', sort_order = 10
WHERE code = 'visitor:host_confirm';

UPDATE permissions
SET module = '常用模块', category = '工资条', sort_order = 20
WHERE code = 'payroll:view:self';

UPDATE permissions
SET module = '常用模块', category = '我的报销', sort_order = 30
WHERE code = 'expense:apply';

UPDATE permissions
SET module = '常用模块', category = '意见箱', sort_order = 40
WHERE code = 'suggestion:submit';

-- 失败关闭：四个自助码必须全部就位且分组里不许混进别的码；
-- 授权策略与基础包口径必须保持 V677/V679 现状（本迁移只挪归类）。
DO $$
BEGIN
    IF (SELECT count(*) FROM permissions
        WHERE (code, category, sort_order) IN (
            ('visitor:host_confirm', '我的访客', 10),
            ('payroll:view:self',    '工资条',   20),
            ('expense:apply',        '我的报销', 30),
            ('suggestion:submit',    '意见箱',   40))
          AND module = '常用模块') <> 4 THEN
        RAISE EXCEPTION 'V831 the four workbench self-service codes must sit in module 常用模块 with card-order categories';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions
               WHERE module = '常用模块'
                 AND code NOT IN ('visitor:host_confirm', 'payroll:view:self',
                                  'expense:apply', 'suggestion:submit')) THEN
        RAISE EXCEPTION 'V831 module 常用模块 must hold exactly the four self-service codes';
    END IF;
    IF (SELECT count(*) FROM permissions
        WHERE code IN ('payroll:view:self', 'expense:apply', 'suggestion:submit')
          AND baseline) <> 3 THEN
        RAISE EXCEPTION 'V831 baseline membership of the three self-service codes must stay unchanged';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM permissions
                   WHERE code = 'visitor:host_confirm' AND NOT baseline
                     AND grant_policy = ARRAY['NON_DELEGABLE']::TEXT[]) THEN
        RAISE EXCEPTION 'V831 visitor host whitelist policy must stay unchanged (V679)';
    END IF;
END $$;
