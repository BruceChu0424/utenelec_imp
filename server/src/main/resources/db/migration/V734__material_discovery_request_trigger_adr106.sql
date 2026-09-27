-- V734 领料申请 LQ 取号触发器按 ADR-106 标准模式重建(2026-09-26)。
--
-- 背景: V731 为 production_material_discovery_requests 挂取号触发器时写成了
-- BEFORE INSERT OR UPDATE OF request_no。V674(ADR-106)已把取号函数
-- fn_reserve_business_document_identifier 的 UPDATE 分支删掉(只剩 INSERT 路径)，
-- 该触发器在 UPDATE OF request_no 起跳时会直接落进 INSERT 取号逻辑，违反取号卫生；
-- 同时它缺少 V674 为每张取号表配的 _upd 不可变守卫
-- (fn_guard_business_document_identifier_immutable + 列级 WHEN)，
-- HotTableTriggerHygieneContractTest 的两条断言都会拒绝。
-- V731 已应用到公司生产库(V733 在其后)，历史迁移字节不能改，故在此新建迁移重建。
-- V731 在 fn_guard_material_discovery_history 里补的 request_no 不可变补丁保留(双保险)。
-- 触发器函数、命名空间与取号语义不变，不加表不加列。

DROP TRIGGER trg_business_document_material_discovery_request ON production_material_discovery_requests;
CREATE TRIGGER trg_business_document_material_discovery_request
    BEFORE INSERT ON production_material_discovery_requests
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier(
        'PRODUCTION_MATERIAL_REQUEST','request_no','');
CREATE TRIGGER trg_business_document_material_discovery_request_upd
    BEFORE UPDATE OF request_no ON production_material_discovery_requests
    FOR EACH ROW WHEN (OLD.request_no IS DISTINCT FROM NEW.request_no
        OR NULLIF(btrim(NEW.request_no),'') IS NULL)
    EXECUTE FUNCTION fn_guard_business_document_identifier_immutable('request_no','');
