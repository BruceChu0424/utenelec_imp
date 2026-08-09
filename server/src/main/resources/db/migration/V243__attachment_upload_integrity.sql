-- V243：附件对象不可复用，并禁止把空对象确认为业务附件。
-- storage_key 是上传能力与数据库绑定的幂等键；缺少唯一约束会允许同一 OSS 对象
-- 被多个业务单据引用，随后任意一方删除都会破坏另一方。

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM attachments
        GROUP BY storage_key
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'attachments 存在重复 storage_key；请先人工核对业务归属，禁止自动覆盖';
    END IF;
END
$$;

ALTER TABLE attachments
    ADD CONSTRAINT attachments_storage_key_uq UNIQUE (storage_key);

ALTER TABLE attachments
    DROP CONSTRAINT attachments_size_chk;

ALTER TABLE attachments
    ADD CONSTRAINT attachments_size_chk CHECK (size_bytes > 0);

COMMENT ON CONSTRAINT attachments_storage_key_uq ON attachments
    IS '一个不可变存储对象只能绑定一条附件元数据；同时作为 confirm 幂等/防重边界';
