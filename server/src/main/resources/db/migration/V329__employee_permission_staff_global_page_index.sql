-- V329: stable cross-department paging for the page-permission staff picker.
--
-- V326 keeps department-scoped paging and trigram contains-search indexes.
-- This complementary partial covering index serves the default empty filter,
-- whose authoritative order is full_name, code, id across all managed roots.

CREATE INDEX idx_employees_current_name_code_page
    ON employees(full_name, code, id)
    INCLUDE (department_id, position_id)
    WHERE is_deleted = FALSE
      AND status IN ('active', 'probation', 'onLeave');

COMMENT ON INDEX idx_employees_current_name_code_page IS
    'Current staff global order for bounded page-permission employee search';
