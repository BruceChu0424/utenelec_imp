-- V765: 车间先申请原料, 仓库首次办理时再由有主档权限的人确认用途。
-- 仅放宽尚未办理的车间领入申请; 退回、仓库直接发料、实际库存流水仍要求 PERIODIC。
CREATE OR REPLACE FUNCTION fn_guard_wm_requisition_line() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    material goods%ROWTYPE;
    requisition workshop_material_requisitions%ROWTYPE;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION '领料单、退回单的明细不能删除'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_requisition_line_guard';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF (to_jsonb(NEW) - 'fulfilled_qty') IS DISTINCT FROM (to_jsonb(OLD) - 'fulfilled_qty') THEN
            RAISE EXCEPTION '领料单、退回单的明细只能记实发数量'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_requisition_line_guard';
        END IF;
        IF NEW.fulfilled_qty > 0 AND NOT EXISTS (
            SELECT 1 FROM goods current_material WHERE current_material.id = NEW.goods_id
              AND NOT current_material.is_deleted AND current_material.issue_method = 'PERIODIC'
              AND current_material.unit_id = NEW.unit_id) THEN
            RAISE EXCEPTION '首次发料需先确认材料用途, 且申请的基本单位必须保持一致'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_requisition_line_guard';
        END IF;
        RETURN NEW;
    END IF;
    SELECT * INTO requisition FROM workshop_material_requisitions WHERE id = NEW.requisition_id;
    IF NOT FOUND OR requisition.status <> 'PENDING' THEN
        RAISE EXCEPTION '已办完或已作废的单据不能再加明细'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_requisition_line_guard';
    END IF;
    IF NEW.fulfilled_qty IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION '新申请只能填写申请数量, 实发数量由仓库实际发料后登记'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_requisition_line_guard';
    END IF;
    SELECT * INTO material FROM goods WHERE id = NEW.goods_id FOR KEY SHARE;
    IF NOT FOUND OR material.is_deleted OR material.unit_id IS DISTINCT FROM NEW.unit_id THEN
        RAISE EXCEPTION '申请材料或基本单位已变化, 请刷新后重新申请'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_requisition_line_guard';
    END IF;
    IF material.issue_method <> 'PERIODIC' AND NOT (
        material.issue_method = 'ORDER' AND material.status = '使用'
        AND requisition.kind = 'ISSUE' AND requisition.origin = 'WORKSHOP_REQUEST'
        AND EXISTS (SELECT 1 FROM unit_measurement_profiles profile JOIN units unit ON unit.id = profile.unit_id
                    WHERE profile.unit_id = material.unit_id AND profile.measurement_dimension = 'MASS'
                      AND NOT unit.is_deleted AND unit.status = '使用')) THEN
        RAISE EXCEPTION '车间可以先申请使用中的重量原料; 退回和直接发料仍需已确认材料用途'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_requisition_line_guard';
    END IF;
    RETURN NEW;
END;
$$;
