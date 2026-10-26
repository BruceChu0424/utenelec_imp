-- New functionality is disabled for existing ordinary accounts until an administrator grants it.
-- Existing grants and the five pinned access permissions are preserved.
ALTER TABLE permissions ADD COLUMN explicit_grant_required boolean NOT NULL DEFAULT false;
ALTER TABLE permissions ALTER COLUMN explicit_grant_required SET DEFAULT true;
ALTER TABLE permissions ALTER COLUMN baseline SET DEFAULT false;

CREATE FUNCTION fn_new_permission_defaults_closed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='INSERT' THEN
        NEW.explicit_grant_required := true;
        NEW.baseline := false;
        NEW.baseline_pinned := false;
    ELSIF OLD.explicit_grant_required AND
          ((NEW.baseline AND NOT OLD.baseline) OR NOT NEW.explicit_grant_required) AND
          nullif(current_setting('app.actor_id',true),'') IS NULL THEN
        RAISE EXCEPTION 'New permissions require an explicit administrator grant' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_new_permission_defaults_closed BEFORE INSERT OR UPDATE ON permissions
FOR EACH ROW EXECUTE FUNCTION fn_new_permission_defaults_closed();

CREATE FUNCTION fn_new_permission_requires_grant_actor() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS(SELECT 1 FROM permissions WHERE id=NEW.permission_id AND explicit_grant_required)
       AND nullif(current_setting('app.actor_id',true),'') IS NULL THEN
        RAISE EXCEPTION 'New permissions cannot be automatically granted to existing accounts or departments'
            USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_new_department_permission_explicit BEFORE INSERT OR UPDATE ON department_permissions
FOR EACH ROW EXECUTE FUNCTION fn_new_permission_requires_grant_actor();
CREATE TRIGGER trg_new_personal_permission_explicit BEFORE INSERT OR UPDATE ON user_permission_overrides
FOR EACH ROW EXECUTE FUNCTION fn_new_permission_requires_grant_actor();
CREATE TRIGGER trg_new_delegated_permission_explicit BEFORE INSERT OR UPDATE ON manager_permission_delegations
FOR EACH ROW EXECUTE FUNCTION fn_new_permission_requires_grant_actor();

INSERT INTO permissions(code,name,module,category,action_type,description,sort_order,grant_policy,baseline,baseline_pinned,high_risk,sensitivity)
VALUES
 ('goods:purchase:edit','编辑货品采购及委外资料','基础资料','货品资料','EDIT',
  '编辑货品来源、默认和次供应商、最小起订量、订货倍数、采购超收及委外允许损耗。委外损耗仍须具备成本查看权限；不含货品基础、销售、售价和组装编辑。',112,ARRAY['NORMAL'],false,false,false,'NORMAL'),
 ('goods:sales:edit','编辑货品销售资料','基础资料','货品资料','EDIT',
  '编辑客户货品名称、客户型号、客户关联和英文名称。不含货品基础、采购委外、售价折扣和组装编辑；英文名称也可单独授权。',113,ARRAY['NORMAL'],false,false,false,'NORMAL');
-- Discoverable in the existing goods page permission drawer; this is catalog membership,
-- never a grant to a department, person, saved template or current delegation.
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT surface.id,permission.id FROM permission_surfaces surface CROSS JOIN permissions permission
WHERE surface.surface_key='basic.goods' AND permission.code IN ('goods:purchase:edit','goods:sales:edit');
UPDATE permissions SET name='编辑货品基础资料',description='编辑货品名称、分类编号、规格材质、颜色单位、包装及生产关联等基础资料。采购委外和销售内容分别授权；售价折扣、状态、成本及组装仍按独立权限校验。' WHERE code='goods:edit';
COMMENT ON COLUMN permissions.explicit_grant_required IS 'V936 后新增权限默认关闭，须由有审计操作人的授权流程显式开通；不复制既有部门、个人或委派授权';
