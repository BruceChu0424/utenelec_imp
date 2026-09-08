-- Retire the inbox while preserving historical grants and notification evidence.
UPDATE permissions
SET active = FALSE, assignable = FALSE,
    description = '已退役：各业务任务入口独立处理，工作台保留任务徽章'
WHERE code = 'review_inbox:view';

DELETE FROM permission_surface_permissions
WHERE surface_id IN (
    SELECT id FROM permission_surfaces WHERE surface_key = 'reviews.inbox');

UPDATE permission_surfaces SET enabled = FALSE
WHERE surface_key = 'reviews.inbox';
