-- Company library: metadata and ACL only; original bytes remain in the scanned private attachment store.
CREATE TABLE company_file_nodes (
    id UUID PRIMARY KEY,
    parent_id UUID REFERENCES company_file_nodes(id),
    kind TEXT NOT NULL CHECK(kind IN ('FOLDER','FILE')),
    name TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 180 AND name=btrim(name)
        AND name NOT IN ('.','..') AND name !~ '[[:cntrl:]/\\]'),
    description TEXT CHECK(length(description)<=2000),
    version BIGINT NOT NULL DEFAULT 0 CHECK(version>=0),
    position BIGINT NOT NULL DEFAULT 0,
    inherit_permissions BOOLEAN NOT NULL DEFAULT true,
    password_hash TEXT,
    password_revision BIGINT NOT NULL DEFAULT 0,
    attachment_id UUID UNIQUE REFERENCES attachments(id),
    size_bytes BIGINT CHECK(size_bytes>0),
    content_type TEXT,
    pending BOOLEAN NOT NULL DEFAULT false,
    deleted BOOLEAN NOT NULL DEFAULT false,
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES users(id),
    deletion_batch UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID NOT NULL REFERENCES users(id),
    updated_by UUID NOT NULL REFERENCES users(id),
    request_id UUID,
    request_fingerprint TEXT,
    CHECK(parent_id IS DISTINCT FROM id),
    CHECK((kind='FOLDER' AND attachment_id IS NULL AND NOT pending AND size_bytes IS NULL)
       OR (kind='FILE' AND password_hash IS NULL AND (pending OR attachment_id IS NOT NULL))),
    CHECK((NOT deleted AND deleted_at IS NULL AND deleted_by IS NULL AND deletion_batch IS NULL)
       OR (deleted AND deleted_at IS NOT NULL AND deleted_by IS NOT NULL AND deletion_batch IS NOT NULL))
);
CREATE UNIQUE INDEX company_file_live_name_uq ON company_file_nodes
    (coalesce(parent_id,'00000000-0000-0000-0000-000000000000'::uuid),lower(name)) WHERE NOT deleted;
CREATE INDEX company_file_parent_idx ON company_file_nodes(parent_id,deleted,position,id);
CREATE INDEX company_file_trash_idx ON company_file_nodes(deleted_at DESC,id) WHERE deleted;
CREATE UNIQUE INDEX company_file_request_uq ON company_file_nodes(created_by,request_id) WHERE request_id IS NOT NULL;
-- Exactly one immutable original per file identity, even if two confirmation requests race.
CREATE UNIQUE INDEX company_file_attachment_owner_uq ON attachments(owner_id)
    WHERE owner_type='COMPANY_FILE' AND lifecycle_state='CLEAN';

CREATE TABLE company_file_acl (
    node_id UUID NOT NULL REFERENCES company_file_nodes(id),
    subject_type TEXT NOT NULL CHECK(subject_type IN ('USER','DEPARTMENT')),
    subject_id UUID NOT NULL,
    effect TEXT NOT NULL CHECK(effect IN ('ALLOW','DENY')),
    actions TEXT[] NOT NULL CHECK(cardinality(actions)>0 AND actions <@ ARRAY[
        'view','download','upload','create','edit','move','delete','restore','manage_permissions']::text[]),
    PRIMARY KEY(node_id,subject_type,subject_id,effect)
);
CREATE INDEX company_file_acl_subject_idx ON company_file_acl(subject_type,subject_id,node_id);
SELECT fn_audit_track_table('company_file_nodes','FULL','data_change',false);
SELECT fn_audit_track_table('company_file_acl','FULL','authorization',false);

-- Serialize tree structure and ACL writes, and reject cycles/depth/invalid parent even outside the API.
CREATE FUNCTION fn_guard_company_file_tree() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE ancestor RECORD; steps INTEGER:=0; subtree_depth INTEGER;
BEGIN
    PERFORM pg_advisory_xact_lock(925,1);
    IF NEW.parent_id IS NOT NULL THEN
        SELECT * INTO ancestor FROM company_file_nodes WHERE id=NEW.parent_id;
        IF NOT FOUND OR ancestor.kind<>'FOLDER' OR (NOT NEW.deleted AND ancestor.deleted) THEN
            RAISE EXCEPTION 'Company file parent is unavailable' USING ERRCODE='23514';
        END IF;
        WHILE ancestor.id IS NOT NULL LOOP
            steps:=steps+1;
            IF ancestor.id=NEW.id OR steps>=32 THEN
                RAISE EXCEPTION 'Company file hierarchy cycle or depth limit' USING ERRCODE='23514';
            END IF;
            SELECT * INTO ancestor FROM company_file_nodes WHERE id=ancestor.parent_id;
            EXIT WHEN NOT FOUND;
        END LOOP;
    END IF;
    IF TG_OP='UPDATE' AND OLD.parent_id IS DISTINCT FROM NEW.parent_id THEN
        WITH RECURSIVE descendants(id,depth,walk) AS (
            SELECT OLD.id,1,ARRAY[OLD.id]
            UNION ALL SELECT child.id,parent.depth+1,parent.walk||child.id
            FROM company_file_nodes child JOIN descendants parent ON child.parent_id=parent.id
            WHERE NOT child.id=ANY(parent.walk) AND parent.depth<=32
        ) SELECT max(depth) INTO subtree_depth FROM descendants;
        IF steps+subtree_depth>32 THEN
            RAISE EXCEPTION 'Company file subtree exceeds depth limit' USING ERRCODE='23514';
        END IF;
    END IF;
    IF NEW.attachment_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM attachments WHERE id=NEW.attachment_id AND owner_type='COMPANY_FILE'
            AND owner_id=NEW.id AND lifecycle_state='CLEAN' AND size_bytes=NEW.size_bytes
            AND content_type=NEW.content_type
    ) THEN
        RAISE EXCEPTION 'Company file original does not match its immutable owner' USING ERRCODE='23514';
    END IF;
    IF TG_OP='UPDATE' AND (OLD.kind IS DISTINCT FROM NEW.kind OR OLD.created_by IS DISTINCT FROM NEW.created_by
        OR OLD.created_at IS DISTINCT FROM NEW.created_at OR OLD.request_id IS DISTINCT FROM NEW.request_id
        OR OLD.request_fingerprint IS DISTINCT FROM NEW.request_fingerprint OR (OLD.attachment_id IS NOT NULL AND
        (OLD.attachment_id IS DISTINCT FROM NEW.attachment_id OR OLD.size_bytes IS DISTINCT FROM NEW.size_bytes
         OR OLD.content_type IS DISTINCT FROM NEW.content_type))) THEN
        RAISE EXCEPTION 'Company file identity and original are immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_company_file_tree BEFORE INSERT OR UPDATE ON company_file_nodes
    FOR EACH ROW EXECUTE FUNCTION fn_guard_company_file_tree();
ALTER TABLE company_file_nodes ENABLE ALWAYS TRIGGER trg_guard_company_file_tree;

INSERT INTO permissions(code,name,module,category,sort_order,action_type,description,grant_policy,baseline)
VALUES
 ('company_file:view','查看公司资料库','常用模块','公司资料库',15,'VIEW','进入资料库并查看已授权目录及文件信息；文件内容另需下载权限。',ARRAY['NORMAL'],true),
 ('company_file:download','下载和预览公司文件','常用模块','公司资料库',16,'EXPORT','下载或预览目录授权范围内的文件原件。',ARRAY['NORMAL'],false),
 ('company_file:upload','上传公司文件','常用模块','公司资料库',17,'CREATE','在授权目录上传新文件，需通过统一安全扫描。',ARRAY['NORMAL'],false),
 ('company_file:create','新建公司文件夹','常用模块','公司资料库',18,'CREATE','在授权目录新建文件夹。',ARRAY['NORMAL'],false),
 ('company_file:edit','编辑公司资料信息','常用模块','公司资料库',19,'EDIT','重命名或编辑授权目录及文件的说明，不覆盖原件。',ARRAY['NORMAL'],false),
 ('company_file:move','移动和排列公司资料','常用模块','公司资料库',20,'EDIT','移动授权文件或目录并调整目录内顺序，同时校验来源及目标授权。',ARRAY['NORMAL'],false),
 ('company_file:delete','移入公司资料回收站','常用模块','公司资料库',21,'DELETE','将授权文件或整棵目录移入回收站，保留原件。',ARRAY['NORMAL'],false),
 ('company_file:restore','还原公司资料','常用模块','公司资料库',22,'EXECUTE','将授权回收站内容还原；同名和父目录状态需重新核对。',ARRAY['NORMAL'],false),
 ('company_file:manage_permissions','管理公司目录权限和密码','常用模块','公司资料库',23,'CONFIGURE','按用户或部门设置目录授权及密码保护；需本人登录密码再认证。',ARRAY['BULK_EXCLUDED'],false);
INSERT INTO permission_surfaces(id,surface_key,name,sort_order,enabled)
VALUES('92500000-0000-4000-8000-000000000001','common.company-files','公司资料库',15,true);
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT '92500000-0000-4000-8000-000000000001'::uuid,id FROM permissions
WHERE code IN ('company_file:view','company_file:download','company_file:upload','company_file:create',
    'company_file:edit','company_file:move','company_file:delete','company_file:restore','company_file:manage_permissions');
-- Keep common-module administration in the same default order as the workbench cards.
UPDATE permissions SET sort_order=30 WHERE code='expense:apply';
UPDATE permissions SET sort_order=40 WHERE code='payroll:view:self';
UPDATE permissions SET sort_order=50 WHERE code='suggestion:submit';
UPDATE permissions SET sort_order=60 WHERE code='visitor:host_confirm';

COMMENT ON TABLE company_file_nodes IS 'Company library identities; original bytes owned by private, malware-scanned attachments';
COMMENT ON COLUMN company_file_nodes.password_hash IS 'BCrypt hash only; audit redaction excludes password_hash';
