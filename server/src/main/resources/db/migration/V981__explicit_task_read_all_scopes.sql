-- Explicit read dimensions only. No ordinary account/department/template receives them by default.
-- They do not change warehouse/workshop responsibility, business actions, subscriptions or badges.
WITH additions(code,source_code,name,description) AS (VALUES
 ('warehouse_task:view:all','stock_doc:view','查看所有仓库的任务',
  '配合对应业务查看权限读取全部物理仓库的任务、历史与详情；不改变仓管职责、办理范围、通知或任务徽章'),
 ('production_workshop_task:view:all','production_execution:view','查看所有车间的任务',
  '配合车间任务查看权限读取全部车间的任务与详情；不改变派工、开工、领料、报工或本人任务资格'),
 ('supplier_return_task:view:all','supplier_return_task:view','查看全部供应商退货任务',
  '配合供应商退货任务查看权限读取全部负责人的任务与详情；不接管、完成他人任务或加入办理提醒')
)
INSERT INTO permissions(code,name,module,category,sort_order,action_type,description,grant_policy,
                        high_risk,baseline,baseline_pinned,sensitivity,explicit_grant_required)
SELECT addition.code,addition.name,source.module,'任务查看范围',source.sort_order+1,'VIEW',addition.description,
       ARRAY['BULK_EXCLUDED','NON_DELEGABLE']::text[],true,false,false,'NORMAL',true
FROM additions addition JOIN permissions source ON source.code=addition.source_code;

DO $$ BEGIN
 IF (SELECT count(*) FROM permissions WHERE code IN
     ('warehouse_task:view:all','production_workshop_task:view:all','supplier_return_task:view:all')) <> 3 THEN
  RAISE EXCEPTION 'Task read-all catalog requires all three existing base-view sources';
 END IF;
END $$;
