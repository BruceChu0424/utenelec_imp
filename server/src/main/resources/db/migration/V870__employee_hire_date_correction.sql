-- 原始任职记录继续 append-only。更正追加新事件，统计使用有来源的有效日期投影。
ALTER TABLE employment_history
    ADD COLUMN corrects_history_id UUID REFERENCES employment_history(id);
COMMENT ON COLUMN employment_history.corrects_history_id IS
    '日期更正引用原始onboard；导入档案无原始onboard时允许NULL，不能虚构历史部门/入职事件，统计继续报告历史缺失';
ALTER TABLE employment_history DROP CONSTRAINT employment_history_event_type_check;
ALTER TABLE employment_history ADD CONSTRAINT employment_history_event_type_check
    CHECK (event_type IN ('onboard', 'transfer', 'resign', 'rehire', 'confirm', 'hire_date_correction'));
ALTER TABLE employment_history ADD CONSTRAINT employment_history_correction_source_chk
    CHECK (event_type = 'hire_date_correction' OR corrects_history_id IS NULL);
CREATE INDEX idx_employment_history_correction_source
    ON employment_history(corrects_history_id) WHERE corrects_history_id IS NOT NULL;

CREATE FUNCTION fn_check_employment_history_correction_source()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.corrects_history_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM employment_history source
        WHERE source.id=NEW.corrects_history_id
          AND source.employee_id=NEW.employee_id AND source.event_type='onboard'
    ) THEN
        RAISE EXCEPTION 'hire-date correction must reference the same employee onboard event'
            USING ERRCODE='23514', CONSTRAINT='employment_history_correction_source_chk';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_employment_history_correction_source
BEFORE INSERT ON employment_history
FOR EACH ROW EXECUTE FUNCTION fn_check_employment_history_correction_source();

CREATE VIEW employment_history_effective AS
SELECT h.id, h.employee_id, h.event_type, h.from_dept_id, h.to_dept_id,
       h.from_position_id, h.to_position_id,
       CASE WHEN h.event_type='onboard' AND EXISTS (
           SELECT 1 FROM employment_history correction
           WHERE correction.corrects_history_id=h.id
             AND correction.event_type='hire_date_correction'
       ) THEN employee.hire_date ELSE h.event_date END AS event_date,
       h.remark, h.created_at, h.updated_at, h.created_by, h.updated_by
FROM employment_history h
JOIN employees employee ON employee.id=h.employee_id
WHERE h.event_type<>'hire_date_correction';
COMMENT ON VIEW employment_history_effective IS
    '有效任职日期投影；原始事件和更正事件均不可变，日期更正不增加入职/复职人数，也不改变任职代次';
