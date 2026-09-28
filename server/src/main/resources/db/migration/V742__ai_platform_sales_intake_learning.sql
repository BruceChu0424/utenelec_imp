-- =====================================================================
-- V742 (ADR-133 / ADR-134) 公共 AI 平台 + 销售客户文件识别 + 主档学习 + 报价财务核价
-- =====================================================================
-- 背景(2026-09-27 用户原话摘要): 新建报价单/订货单时上传客户自己的报价单或形式发票,
--   格式各不相同、货品多为英文(也有其他语言); 由系统对应到我们的货品资料, 价格不许改,
--   按文件单价算折扣, 自动填表头与货品明细; 用户确认保存后学习客户的叫法(货品英文名、
--   客户资料), 上传越多资料越完整; AI 先用第三方接口, 以后换本机部署, 服务商在系统设置
--   里填写并能测试连接, 密钥加密显示; 报价单不是最终的, 财务核价确认后才转订货单,
--   订货单才是最终的。
--
-- 本迁移只建结构、播种与登记, 业务逻辑在服务端(features/ai、features/sales/intake、
--   features/master/learning、报价核价流程):
--   (a) ai_providers            AI 服务商配置(密钥只存 SecretCipher 密文, 审计只记非密钥列)
--   (b) ai_jobs                 AI 识别任务队列(上传文件在终态同一事务内清空)
--   (c) ai_call_logs            每次调用的技术记录(不存提示词/回复/密钥)
--   (d) goods.name_en(+来源) / clients.name_en 与两个货品检索索引
--   (e) client_goods_aliases    客户货品对照(客户的型号/品名 → 我们的货品, 学习得来)
--   (f) sales_intake_layouts    客户文件版式(表头指纹 → 列角色, 学习得来)
--   (g) 报价/订货明细的文件型号、文件品名、文件单价, 报价明细的折扣与财务定价来源
--   (h) 报价表头的财务核价字段与状态 2(待财务核价)
--   (i) sales_quote_revision_logs 报价核价修订记录(只追加)
--   (j) 权限: sales_quote_finance:view/confirm、ai:use、goods:name_en:edit 新增并按现有持有人回填;
--       sales_quote:approve 退役(报价不再由销售审核, 改为财务核价确认)
--   (k) 登记: 审计三清单、清库策略孪生补丁、历史订货的客户型号播种为对照
--
-- 登记(新表六张 + 迁移头): 审计三清单 ai_providers COLUMN_SCOPED(system, 不挂新增/删除
--   触发器, 新建/删除/换密钥由 AuditService 显式事件记录), 其余五张 NONE(ai_jobs queue、
--   ai_call_logs technical、client_goods_aliases 与 sales_intake_layouts preference、
--   sales_quote_revision_logs ledger); 清库策略 ai_providers / client_goods_aliases /
--   sales_intake_layouts PRESERVE, ai_jobs / ai_call_logs / sales_quote_revision_logs CLEAR;
--   主档引用目录 client_goods_aliases.client_id/.goods_id 与 sales_intake_layouts.client_id
--   豁免 OWN_CONFIG, 报价在办口径改为 草稿/待核价/已核价未转订货。
-- 版本号是临时号: Flyway 不允许乱序, 合并时按磁盘最大号顺延并同步全部迁移头登记。
-- =====================================================================

-- ---------------------------------------------------------------------
-- (a) AI 服务商配置
-- ---------------------------------------------------------------------
CREATE TABLE ai_providers (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name              VARCHAR(64) NOT NULL CHECK (length(btrim(name)) > 0),
    preset            VARCHAR(32) NOT NULL CHECK (preset IN (
                          'DEEPSEEK', 'DASHSCOPE', 'MOONSHOT', 'ZHIPU', 'VOLCENGINE', 'SILICONFLOW',
                          'OPENAI', 'ANTHROPIC', 'GEMINI', 'OLLAMA', 'VLLM', 'CUSTOM')),
    region            VARCHAR(16) NOT NULL CHECK (region IN ('MAINLAND', 'OVERSEAS', 'LOCAL')),
    protocol          VARCHAR(24) NOT NULL CHECK (protocol IN ('OPENAI_CHAT', 'ANTHROPIC_MESSAGES')),
    base_url          VARCHAR(512) NOT NULL CHECK (length(btrim(base_url)) > 0),
    model             VARCHAR(128) NOT NULL CHECK (length(btrim(model)) > 0),
    secret            TEXT,
    api_key_last4     VARCHAR(8),
    json_mode         VARCHAR(16) NOT NULL DEFAULT 'JSON_OBJECT'
                          CHECK (json_mode IN ('NONE', 'JSON_OBJECT', 'JSON_SCHEMA')),
    thinking_control  VARCHAR(24) NOT NULL DEFAULT 'NONE'
                          CHECK (thinking_control IN ('NONE', 'DEEPSEEK', 'DASHSCOPE', 'OPENAI_REASONING')),
    send_temperature  BOOLEAN NOT NULL DEFAULT TRUE,
    supports_vision   BOOLEAN NOT NULL DEFAULT FALSE,
    max_output_tokens INTEGER NOT NULL DEFAULT 8192 CHECK (max_output_tokens BETWEEN 256 AND 65536),
    timeout_seconds   INTEGER NOT NULL DEFAULT 120 CHECK (timeout_seconds BETWEEN 10 AND 600),
    enabled           BOOLEAN NOT NULL DEFAULT TRUE,
    is_default        BOOLEAN NOT NULL DEFAULT FALSE,
    overseas_ack_by   UUID,
    overseas_ack_at   TIMESTAMPTZ,
    last_test_at      TIMESTAMPTZ,
    last_test_ok      BOOLEAN,
    last_test_message VARCHAR(500),
    version           BIGINT NOT NULL DEFAULT 0,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        UUID,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by        UUID,
    -- 密钥尾号只在确有密文时存在(清除密钥时两列一起清空)。
    CONSTRAINT ck_ai_providers_key_tail CHECK (secret IS NOT NULL OR api_key_last4 IS NULL),
    -- 境外服务商必须带数据出境确认(谁、何时确认)。
    CONSTRAINT ck_ai_providers_overseas_ack CHECK (region <> 'OVERSEAS' OR overseas_ack_at IS NOT NULL)
);

CREATE UNIQUE INDEX uq_ai_providers_name ON ai_providers (lower(name));
-- 至多一个默认服务商。
CREATE UNIQUE INDEX uq_ai_providers_default ON ai_providers (is_default) WHERE is_default;

COMMENT ON TABLE ai_providers IS
    'ADR-133 公共 AI 平台的服务商配置(DeepSeek/通义/Kimi/智谱/豆包/本机部署等, 超管在系统设置里维护)。密钥只存 SecretCipher 密文, 接口从不返回明文; 审计只记非密钥列, 新建/删除/换密钥另有显式审计事件';
COMMENT ON COLUMN ai_providers.secret IS
    'SecretCipher 密文(格式 g<密钥版本>:base64url(iv||密文+标签), AAD 绑定服务商 id); 列名 secret 同时在 fn_audit_redact_row 的剔除清单里';
COMMENT ON COLUMN ai_providers.api_key_last4 IS
    '密钥尾号(只在密钥长度 >= 20 时保存), 用于设置页「已配置 ••••abcd」显示';
COMMENT ON COLUMN ai_providers.region IS
    'MAINLAND 境内服务商 / OVERSEAS 境外服务商(默认禁用, 需服务端开关与数据出境确认) / LOCAL 本机或内网部署';
COMMENT ON COLUMN ai_providers.overseas_ack_at IS
    '境外服务商的数据出境确认时间(确认人 overseas_ack_by, users.id)';

-- ---------------------------------------------------------------------
-- (b) AI 识别任务队列
-- ---------------------------------------------------------------------
CREATE TABLE ai_jobs (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind                   VARCHAR(48) NOT NULL,
    status                 VARCHAR(16) NOT NULL DEFAULT 'PENDING'
                               CHECK (status IN ('PENDING', 'RUNNING', 'SUCCEEDED', 'FAILED', 'CANCELLED')),
    stage                  VARCHAR(48),
    progress               INTEGER NOT NULL DEFAULT 0 CHECK (progress BETWEEN 0 AND 100),
    cancel_requested       BOOLEAN NOT NULL DEFAULT FALSE,
    params                 JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(params) = 'object'),
    input_name             VARCHAR(255) NOT NULL,
    input_content_type     VARCHAR(128) NOT NULL,
    input_kind             VARCHAR(16) NOT NULL,
    input_size             BIGINT NOT NULL CHECK (input_size >= 0),
    input_sha256           VARCHAR(64) NOT NULL CHECK (input_sha256 ~ '^[0-9a-f]{64}$'),
    input_bytes            BYTEA,
    result                 JSONB,
    error_code             VARCHAR(48),
    error_message          VARCHAR(1000),
    submitted_by_user      UUID NOT NULL,
    submitted_by_employee  UUID,
    submitted_auth_version BIGINT NOT NULL,
    submitted_auth_epoch   BIGINT,
    ai_calls               INTEGER NOT NULL DEFAULT 0 CHECK (ai_calls >= 0),
    attempts               INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    lease_until            TIMESTAMPTZ,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_at             TIMESTAMPTZ,
    finished_at            TIMESTAMPTZ,
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    used_at                TIMESTAMPTZ,
    used_doc_type          VARCHAR(24),
    used_doc_id            UUID,
    result_purged_at       TIMESTAMPTZ,
    -- 进入终态(成功/失败/取消)的同一条 UPDATE 必须清空上传文件, 文件不在库里过夜。
    CONSTRAINT ck_ai_jobs_terminal_input_released
        CHECK (status IN ('PENDING', 'RUNNING') OR input_bytes IS NULL)
);

-- 后台工作线程按创建顺序认领待办任务(FOR UPDATE SKIP LOCKED)与过期租约回收。
CREATE INDEX idx_ai_jobs_status_created ON ai_jobs (status, created_at);
-- 每人进行中任务数、每日任务数限额与「我的任务」。
CREATE INDEX idx_ai_jobs_submitter_created ON ai_jobs (submitted_by_user, created_at DESC);
-- 同一文件 10 分钟内重复提交直接复用; 重复单据检查按文件指纹回查已用任务。
CREATE INDEX idx_ai_jobs_input_sha256 ON ai_jobs (input_sha256);

COMMENT ON TABLE ai_jobs IS
    'ADR-133 AI 识别任务: 上传即建 PENDING, 后台线程以提交人的权限处理, 结果只给提交人本人读取。上传文件在终态同一事务内清空, 结果在使用后或 48 小时后清空, 任务 7 天后删除';
COMMENT ON COLUMN ai_jobs.input_bytes IS
    '上传的原始文件; 进入 SUCCEEDED/FAILED/CANCELLED 的同一事务内置空(ck_ai_jobs_terminal_input_released)';
COMMENT ON COLUMN ai_jobs.input_sha256 IS
    '上传文件的 SHA-256(64 位小写十六进制), 用于 10 分钟内重复提交复用与重复单据提示';
COMMENT ON COLUMN ai_jobs.submitted_auth_version IS
    '提交时账号的 users.auth_version; 后台处理前与当前值比对, 权限变化即失败「账号权限已变化, 请重新识别」';
COMMENT ON COLUMN ai_jobs.submitted_auth_epoch IS
    '提交时的 authorization_state.epoch(全局授权纪元), 与 JWT ae 声明同口径';
COMMENT ON COLUMN ai_jobs.used_doc_type IS
    '结果被保存进哪类单据(quote/order), used_doc_id 为该单据 id; 使用后结果即清空(result_purged_at)';

-- ---------------------------------------------------------------------
-- (c) AI 调用技术记录(不存提示词、回复与密钥)
-- ---------------------------------------------------------------------
CREATE TABLE ai_call_logs (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    purpose        VARCHAR(48) NOT NULL,
    provider_id    UUID REFERENCES ai_providers(id) ON DELETE SET NULL,
    provider_name  VARCHAR(64),
    model          VARCHAR(128),
    protocol       VARCHAR(24),
    ok             BOOLEAN NOT NULL,
    error_category VARCHAR(32),
    http_status    INTEGER,
    input_tokens   INTEGER CHECK (input_tokens >= 0),
    output_tokens  INTEGER CHECK (output_tokens >= 0),
    latency_ms     INTEGER NOT NULL CHECK (latency_ms >= 0),
    job_id         UUID,
    user_id        UUID
);

-- 设置页近 30 天用量、当日 token 预算与 180 天清理都按时间倒序扫。
CREATE INDEX idx_ai_call_logs_created ON ai_call_logs (created_at DESC);

COMMENT ON TABLE ai_call_logs IS
    'ADR-133 每次 AI 调用一行技术记录(用途、服务商、模型、成败、token、耗时); 不存提示词、回复与密钥, 180 天后清理';

-- ---------------------------------------------------------------------
-- (d) 货品英文名称 / 客户外文名称
-- ---------------------------------------------------------------------
ALTER TABLE goods
    ADD COLUMN name_en VARCHAR(255),
    ADD COLUMN name_en_source VARCHAR(8) CHECK (name_en_source IN ('MANUAL', 'LEARNED'));

ALTER TABLE clients
    ADD COLUMN name_en VARCHAR(255);

-- 英文名称相似检索(候选召回); 中文相似度在 Java 里按字二元组计算, 不用 pg_trgm。
CREATE INDEX idx_goods_name_en_trgm
    ON goods USING gin (lower(name_en) gin_trgm_ops)
    WHERE NOT is_deleted AND name_en IS NOT NULL;
-- 型号精确匹配(候选召回): 与 Java normalizePart 同口径(NFKC、全角斜杠与各种横线统一、去全部空白、
-- 大写、去掉末尾一个句点), 与下方客户型号种子同一表达式; 服务端查询必须写同一表达式才能走索引。
CREATE INDEX idx_goods_model_norm
    ON goods ((regexp_replace(upper(regexp_replace(
        translate(normalize(coalesce(model, ''), NFKC), '／－—–', '/---'), '\s+', '', 'g')), '\.$', '')))
    WHERE NOT is_deleted AND model IS NOT NULL AND btrim(model) <> '';

COMMENT ON COLUMN goods.name_en IS
    'ADR-134 货品英文名称: 货品资料里人工维护(来源 MANUAL), 或销售保存报价/订货单时勾选「设为货品英文名」由客户文件学习(来源 LEARNED); 保持最新一次确认的值';
COMMENT ON COLUMN goods.name_en_source IS
    '英文名称来源: MANUAL 人工维护 / LEARNED 从客户文件学习; 名称为空时为空';
COMMENT ON COLUMN clients.name_en IS
    'ADR-134 客户外文名称(客户文件上的英文公司名), 人工维护或保存单据时从客户文件补全; 客户识别按它精确匹配';

-- ---------------------------------------------------------------------
-- (e) 客户货品对照(SAP CMIR / 金蝶「客户物料对应表」同类)
-- ---------------------------------------------------------------------
CREATE TABLE client_goods_aliases (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id            UUID REFERENCES clients(id) ON DELETE CASCADE,
    alias_kind           VARCHAR(16) NOT NULL CHECK (alias_kind IN ('PART_NO', 'DESCRIPTION')),
    alias_text           VARCHAR(500) NOT NULL CHECK (length(btrim(alias_text)) > 0),
    alias_norm           VARCHAR(500) NOT NULL CHECK (length(alias_norm) > 0),
    context_norm         VARCHAR(200) NOT NULL DEFAULT '',
    goods_id             UUID NOT NULL REFERENCES goods(id) ON DELETE CASCADE,
    confirm_count        INTEGER NOT NULL DEFAULT 1 CHECK (confirm_count >= 1),
    explicit_count       INTEGER NOT NULL DEFAULT 0 CHECK (explicit_count >= 0),
    first_confirmed_at   TIMESTAMPTZ NOT NULL,
    last_confirmed_at    TIMESTAMPTZ NOT NULL,
    last_confirmed_by    UUID,
    last_source_doc_type VARCHAR(16),
    last_source_doc_id   UUID,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_client_goods_aliases_time_order CHECK (last_confirmed_at >= first_confirmed_at),
    -- 同一客户(空 = 全局)、同一叫法、同一上下文到同一货品只有一行; 这把唯一索引同时服务
    -- (client_id, alias_kind, alias_norm) 前缀查询, 不另建重复索引(索引卫生契约)。
    CONSTRAINT uq_client_goods_aliases_key
        UNIQUE NULLS NOT DISTINCT (client_id, alias_kind, alias_norm, context_norm, goods_id)
);

COMMENT ON TABLE client_goods_aliases IS
    'ADR-134 客户货品对照: 客户文件上的型号(PART_NO)或品名(DESCRIPTION) → 我们的货品。销售确认保存报价/订货单后自动学习; client_id 为空 = 全局对照(只从识别结果里的原文学习, 至少 2 次确认才用)。用户在客户资料「货品对照」里删除时另写审计事件';
COMMENT ON COLUMN client_goods_aliases.alias_norm IS
    '规范化后的叫法: PART_NO 与 Java normalizePart 同口径(NFKC、全角斜杠/各种横线统一、去全部空白、大写、去掉末尾一个句点); DESCRIPTION 与 normalizeDescription 同口径';
COMMENT ON COLUMN client_goods_aliases.context_norm IS
    '该行上下文(规范化的「系列|主色」), 未知时为空串; 同一叫法在不同系列/颜色下可指向不同货品';
COMMENT ON COLUMN client_goods_aliases.confirm_count IS
    '被保存确认的次数(同一张单据重复保存不重复计数)';
COMMENT ON COLUMN client_goods_aliases.explicit_count IS
    '用户在识别面板或明细里明确选择/改成这个货品的次数(>= 1 或确认 >= 2 次才算权威对照)';
COMMENT ON COLUMN client_goods_aliases.last_source_doc_type IS
    '最近一次确认来自哪类单据(quote/order), last_source_doc_id 为单据 id; 单据属清空数据, 故不建外键';

-- ---------------------------------------------------------------------
-- (f) 客户文件版式(表头指纹 → 列角色)
-- ---------------------------------------------------------------------
CREATE TABLE sales_intake_layouts (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fingerprint       VARCHAR(64) NOT NULL CHECK (fingerprint ~ '^[0-9a-f]{64}$'),
    client_id         UUID REFERENCES clients(id) ON DELETE CASCADE,
    header_texts      TEXT NOT NULL,
    column_roles      JSONB NOT NULL,
    header_row_offset INTEGER NOT NULL DEFAULT 0 CHECK (header_row_offset >= 0),
    confirm_count     INTEGER NOT NULL DEFAULT 1 CHECK (confirm_count >= 1),
    last_used_at      TIMESTAMPTZ NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_sales_intake_layouts_key UNIQUE NULLS NOT DISTINCT (fingerprint, client_id)
);

COMMENT ON TABLE sales_intake_layouts IS
    'ADR-134 客户文件版式: 表头行规范化文本的指纹(SHA-256, 64 位小写十六进制) → 各列角色(型号/品名/数量/单价…)。保存单据后学习; client_id 为空 = 全局版式。下次同版式文件直接按它取列, 不再调用 AI';

-- ---------------------------------------------------------------------
-- (g) 报价/订货明细: 文件型号、文件品名、文件单价; 报价明细折扣与财务定价来源
-- ---------------------------------------------------------------------
ALTER TABLE sales_quote_items
    ADD COLUMN discount NUMERIC(18,4) NOT NULL DEFAULT 1 CHECK (discount > 0 AND discount <= 1),
    ADD COLUMN price_source VARCHAR(8) NOT NULL DEFAULT 'MASTER' CHECK (price_source IN ('MASTER', 'FINANCE')),
    ADD COLUMN finance_price_by UUID,
    ADD COLUMN finance_price_at TIMESTAMPTZ,
    ADD COLUMN client_model VARCHAR(128),
    ADD COLUMN client_goods_name VARCHAR(500),
    ADD COLUMN client_price NUMERIC CHECK (client_price >= 0),
    ADD CONSTRAINT ck_sales_quote_items_finance_price
        CHECK (price_source = 'MASTER' OR finance_price_at IS NOT NULL);

ALTER TABLE sales_order_items
    ADD COLUMN client_goods_name VARCHAR(500),
    ADD COLUMN client_price NUMERIC CHECK (client_price >= 0);

COMMENT ON COLUMN sales_quote_items.discount IS
    'ADR-134 折扣(0 < 折扣 <= 1, 4 位小数): 金额 = 数量 × 单价 × 折扣; 草稿由销售填写或按文件单价推算, 待核价期间由财务核定';
COMMENT ON COLUMN sales_quote_items.price_source IS
    '单价来源: MASTER 货品资料售价(销售不能改) / FINANCE 财务核价时设定的成交单价(货品未维护售价或客户价高于标价时)';
COMMENT ON COLUMN sales_quote_items.finance_price_by IS
    '设定财务成交单价的员工(employees.id), 与 finance_price_at 一起记录';
COMMENT ON COLUMN sales_quote_items.client_model IS
    '客户文件上的型号/货号原文(学习客户货品对照用)';
COMMENT ON COLUMN sales_quote_items.client_goods_name IS
    '客户文件上的品名/描述原文(学习客户货品对照与货品英文名用)';
COMMENT ON COLUMN sales_quote_items.client_price IS
    '客户文件上的单价原文数值, 币种见表头 client_file_currency; 只作参考, 从不参与金额计算';
COMMENT ON COLUMN sales_order_items.client_goods_name IS
    'ADR-134 客户文件上的品名/描述原文(型号原文沿用既有 client_model)';
COMMENT ON COLUMN sales_order_items.client_price IS
    'ADR-134 客户文件上的单价原文数值, 币种见表头 client_file_currency; 只作参考, 从不参与金额计算';

-- ---------------------------------------------------------------------
-- (h) 报价表头: 财务核价字段; 订货表头: 客户文件币种
-- ---------------------------------------------------------------------
ALTER TABLE sales_quotes
    ADD COLUMN currency_id UUID REFERENCES currencies(id),
    ADD COLUMN seller_id UUID REFERENCES employees(id),
    ADD COLUMN deliver_date DATE,
    ADD COLUMN settlement_method_id UUID,
    ADD COLUMN contract_no VARCHAR(64),
    ADD COLUMN client_file_currency VARCHAR(8),
    ADD COLUMN submitted_at TIMESTAMPTZ,
    ADD COLUMN submitted_by UUID,
    ADD COLUMN finance_confirmed_at TIMESTAMPTZ,
    ADD COLUMN finance_confirmed_by UUID,
    ADD COLUMN finance_returned_at TIMESTAMPTZ,
    ADD COLUMN finance_returned_by UUID,
    ADD COLUMN finance_return_reason VARCHAR(500),
    ADD COLUMN finance_remark VARCHAR(500),
    ADD COLUMN review_revision INTEGER NOT NULL DEFAULT 0 CHECK (review_revision >= 0),
    -- 与 sales_orders.settlement_method_id(fk_sales_orders_settlement_method)同一目标与删除规则。
    ADD CONSTRAINT fk_sales_quotes_settlement_method
        FOREIGN KEY (settlement_method_id) REFERENCES settlement_methods(id) ON DELETE RESTRICT,
    -- V51 起报价状态没有 CHECK; 新增 2(待财务核价)后把合法取值钉死。
    ADD CONSTRAINT ck_sales_quotes_status CHECK (status IN (-1, 0, 1, 2));

ALTER TABLE sales_orders
    ADD COLUMN client_file_currency VARCHAR(8);

COMMENT ON COLUMN sales_quotes.status IS
    'ADR-134 报价状态: 0 草稿(finance_return_reason 非空 = 财务退回待修改) / 2 待财务核价 / 1 财务已确认(可转订货单) / -1 作废';
COMMENT ON COLUMN sales_quotes.client_file_currency IS
    '客户文件上单价的币种代码(如 USD), 供核价时正确阅读 client_price; 单据本身按本位币计价';
COMMENT ON COLUMN sales_quotes.submitted_by IS
    '最近一次提交财务核价的员工(employees.id, 与 maker_id 同口径)';
COMMENT ON COLUMN sales_quotes.finance_confirmed_by IS
    '财务确认报价的员工(employees.id, 与 sales_orders.finance_confirmed_by 同口径)';
COMMENT ON COLUMN sales_quotes.finance_returned_by IS
    '财务退回报价的员工(employees.id); 退回原因见 finance_return_reason, 重新提交时清空';
COMMENT ON COLUMN sales_quotes.review_revision IS
    '核价修订号: 提交/撤回/财务修改/退回/确认/重新打开各加 1, 所有核价动作带 expectedRevision 防并发覆盖';
COMMENT ON COLUMN sales_orders.client_file_currency IS
    'ADR-134 客户文件上单价的币种代码(如 USD), 供阅读明细 client_price; 订单本身的币种仍是 currency_id';

-- ---------------------------------------------------------------------
-- (i) 报价核价修订记录(只追加)
-- ---------------------------------------------------------------------
CREATE TABLE sales_quote_revision_logs (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    quote_id   UUID NOT NULL REFERENCES sales_quotes(id) ON DELETE CASCADE,
    revision   INTEGER NOT NULL CHECK (revision >= 0),
    action     VARCHAR(24) NOT NULL CHECK (action IN (
                   'SUBMIT', 'WITHDRAW', 'FINANCE_EDIT', 'RETURN', 'CONFIRM', 'REOPEN', 'FINANCE_REOPEN')),
    actor_id   UUID,
    reason     VARCHAR(500),
    snapshot   JSONB NOT NULL CHECK (jsonb_typeof(snapshot) = 'object'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_sales_quote_revision_logs_quote
    ON sales_quote_revision_logs (quote_id, created_at);

-- 修订记录只追加(与 V492 sales_order_revision_logs 同口径); 删除只随报价级联或清库发生。
CREATE FUNCTION fn_sales_quote_revision_logs_immutable() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Sales quote revision facts are append-only';
END;
$$;
CREATE TRIGGER trg_sales_quote_revision_logs_immutable
    BEFORE UPDATE ON sales_quote_revision_logs
    FOR EACH ROW EXECUTE FUNCTION fn_sales_quote_revision_logs_immutable();

COMMENT ON TABLE sales_quote_revision_logs IS
    'ADR-134 报价核价修订记录: 每次提交、撤回、财务修改、退回、确认、重新打开追加一行(含明细快照), 只追加不修改; 核价页显示历次修订与上次财务确认的折扣';
COMMENT ON COLUMN sales_quote_revision_logs.actor_id IS
    '操作员工(employees.id)';

-- ---------------------------------------------------------------------
-- (k1) 审计三清单(ADR-105)
-- ---------------------------------------------------------------------
-- 服务商配置只审计非密钥列; 不挂新增/删除触发器(整行会带上密文), 新建/删除/换密钥由
-- AuditService 显式事件记录。
SELECT fn_audit_track_table('ai_providers', 'COLUMN_SCOPED', 'system', false,
    ARRAY['name', 'preset', 'region', 'protocol', 'base_url', 'model', 'json_mode', 'thinking_control', 'send_temperature', 'supports_vision', 'max_output_tokens', 'timeout_seconds', 'enabled', 'is_default'], false);
-- 队列、技术记录、自动学习与只追加修订记录不挂行级审计。
SELECT fn_audit_track_table('ai_jobs', 'NONE', 'data_change', false);
SELECT fn_audit_track_table('ai_call_logs', 'NONE', 'data_change', false);
SELECT fn_audit_track_table('client_goods_aliases', 'NONE', 'data_change', false);
SELECT fn_audit_track_table('sales_intake_layouts', 'NONE', 'data_change', false);
SELECT fn_audit_track_table('sales_quote_revision_logs', 'NONE', 'data_change', false);

-- ---------------------------------------------------------------------
-- (k2) 清库策略: 配置与学习知识随主档保留, 任务、调用记录与修订记录随业务数据清空。
--      沿用 V686/V693 锚点补丁法, 锚点缺失或不唯一即失败。
-- ---------------------------------------------------------------------
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V742 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition, anchor, anchor
        || E',\n            (''ai_jobs'', ''CLEAR''),'
        || E'\n            (''ai_call_logs'', ''CLEAR''),'
        || E'\n            (''sales_quote_revision_logs'', ''CLEAR''),'
        || E'\n            (''ai_providers'', ''PRESERVE''),'
        || E'\n            (''client_goods_aliases'', ''PRESERVE''),'
        || E'\n            (''sales_intake_layouts'', ''PRESERVE'')');
END;
$reset_policy$;

-- ---------------------------------------------------------------------
-- (e2) 播种: 历史订货明细上的客户型号 → 该客户的 PART_NO 对照(确认次数 = 订单数)。
--      只取未作废、未删除的订单与明细, 未删除的客户与非占位货品; 不播种全局对照。
--      规范化表达式与 Java normalizePart 同口径(有对拍单元测试)。重跑不重复插入。
-- ---------------------------------------------------------------------
WITH source_lines AS (
    SELECT sales_order.client_id,
           item.goods_id,
           sales_order.id AS order_id,
           sales_order.bill_date,
           sales_order.created_at,
           item.id AS item_id,
           btrim(item.client_model) AS alias_text,
           regexp_replace(
               upper(regexp_replace(
                   translate(normalize(btrim(item.client_model), NFKC), '／－—–', '/---'),
                   '\s+', '', 'g')),
               '\.$', '') AS alias_norm
    FROM sales_order_items item
    JOIN sales_orders sales_order ON sales_order.id = item.order_id
    JOIN clients client ON client.id = sales_order.client_id AND NOT client.is_deleted
    JOIN goods goods ON goods.id = item.goods_id AND NOT goods.is_deleted AND NOT goods.auto_created
    WHERE NOT item.is_deleted
      AND NOT sales_order.is_deleted
      AND sales_order.status <> -1
      AND item.client_model IS NOT NULL
      AND btrim(item.client_model) <> ''
      AND char_length(btrim(item.client_model)) <= 500
), grouped AS (
    SELECT client_id,
           alias_norm,
           goods_id,
           (array_agg(alias_text ORDER BY bill_date DESC, created_at DESC, item_id DESC))[1] AS alias_text,
           count(DISTINCT order_id)::INTEGER AS confirm_count,
           min(bill_date) AS first_date,
           max(bill_date) AS last_date,
           (array_agg(order_id ORDER BY bill_date DESC, created_at DESC, item_id DESC))[1] AS last_order_id
    FROM source_lines
    WHERE char_length(alias_norm) BETWEEN 1 AND 500
    GROUP BY client_id, alias_norm, goods_id
)
INSERT INTO client_goods_aliases (
    client_id, alias_kind, alias_text, alias_norm, context_norm, goods_id,
    confirm_count, explicit_count, first_confirmed_at, last_confirmed_at,
    last_confirmed_by, last_source_doc_type, last_source_doc_id)
SELECT client_id, 'PART_NO', alias_text, alias_norm, '', goods_id,
       confirm_count, 0,
       first_date::TIMESTAMP AT TIME ZONE 'Asia/Shanghai',
       last_date::TIMESTAMP AT TIME ZONE 'Asia/Shanghai',
       NULL, 'order', last_order_id
FROM grouped
ORDER BY client_id, alias_norm, goods_id
ON CONFLICT ON CONSTRAINT uq_client_goods_aliases_key DO NOTHING;

-- ---------------------------------------------------------------------
-- (j) 权限
-- ---------------------------------------------------------------------
-- ① 新权限码(模块/分类: 核价码随 sales_order_finance:* 归 财税管理, V294; 财税模块的
--    审批类码一律标高危; ai:use 放在销售能找到的 销售管理 下; 英文名称码随货品资料)。
INSERT INTO permissions (code, name, module, category, sort_order, action_type, description,
                         grant_policy, high_risk)
VALUES
    ('sales_quote_finance:view', '查看销售报价核价任务', '财税管理', '报价核价', 598,
     'VIEW', '查看待核价、已核价与财务退回的销售报价(只读)',
     ARRAY['NORMAL']::text[], FALSE),
    ('sales_quote_finance:confirm', '销售报价财务核价', '财税管理', '报价核价', 599,
     'APPROVE', '认领销售报价并核定折扣或成交单价, 退回销售修改或确认报价(确认后销售才能转订货单)',
     ARRAY['NORMAL']::text[], TRUE),
    ('ai:use', '使用 AI 识别客户文件', '销售管理', 'AI 识别', 207,
     'EXECUTE', '识别客户报价单/形式发票时调用系统设置里的 AI 服务; 没有此权限时只按固定规则识别常见格式的 Excel',
     ARRAY['NORMAL']::text[], FALSE),
    ('goods:name_en:edit', '维护货品英文名称', '基础资料', '货品资料', 24,
     'EDIT', '只修改货品英文名称(含保存报价/订货单时勾选「设为货品英文名」); 持有编辑货品资料权限的人同样可以修改',
     ARRAY['NORMAL']::text[], FALSE)
ON CONFLICT (code) DO UPDATE SET
    name = EXCLUDED.name, module = EXCLUDED.module, category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order, action_type = EXCLUDED.action_type,
    description = EXCLUDED.description, grant_policy = EXCLUDED.grant_policy,
    high_risk = EXCLUDED.high_risk;

-- ② 页面权限面: 新增「销售报价核价」面; ai:use 与英文名称码挂在用到它们的页面上
--    (V328 之后新增码须显式挂面, 否则负责人无处可授)。
INSERT INTO permission_surfaces (id, surface_key, name, sort_order, enabled) VALUES
    ('74200000-0000-4000-8000-000000000001', 'finance.sales-quote-review', '销售报价核价', 279, TRUE)
ON CONFLICT (surface_key) DO NOTHING;

WITH mapping(surface_key, permission_code) AS (VALUES
    ('finance.sales-quote-review', 'sales_quote_finance:view'),
    ('finance.sales-quote-review', 'sales_quote_finance:confirm'),
    ('finance.hub', 'sales_quote_finance:view'),
    ('sales.quote', 'ai:use'),
    ('sales.order', 'ai:use'),
    ('sales.quote', 'goods:name_en:edit'),
    ('sales.order', 'goods:name_en:edit'),
    ('basic.goods', 'goods:name_en:edit')
)
INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN mapping m ON surface.surface_key = m.surface_key
JOIN permissions permission ON permission.code = m.permission_code
WHERE surface.enabled
ON CONFLICT DO NOTHING;

-- ③ 回填: 报价核价跟随订单财务确认(持有 sales_order_finance:confirm 的部门获得两码);
--    ai:use 与英文名称码跟随销售开单(持有 sales_order:create 或 sales_quote:create 的部门)。
INSERT INTO department_permissions (department_id, permission_id)
SELECT DISTINCT holder.department_id, granted.id
FROM department_permissions holder
JOIN permissions source ON source.id = holder.permission_id
                       AND source.code = 'sales_order_finance:confirm'
JOIN permissions granted ON granted.code IN ('sales_quote_finance:view', 'sales_quote_finance:confirm')
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions (department_id, permission_id)
SELECT DISTINCT holder.department_id, granted.id
FROM department_permissions holder
JOIN permissions source ON source.id = holder.permission_id
                       AND source.code IN ('sales_order:create', 'sales_quote:create')
JOIN permissions granted ON granted.code IN ('ai:use', 'goods:name_en:edit')
ON CONFLICT DO NOTHING;

-- ④ 退役 sales_quote:approve: 报价不再由销售审核, 改为提交财务核价、财务确认。
--    先删页面权限面映射(外键 RESTRICT), 部门授权/个人覆盖/委派随外键级联删除。
DELETE FROM permission_surface_permissions mapping
USING permissions permission
WHERE mapping.permission_id = permission.id
  AND permission.code = 'sales_quote:approve';

DELETE FROM permissions
WHERE code = 'sales_quote:approve';
