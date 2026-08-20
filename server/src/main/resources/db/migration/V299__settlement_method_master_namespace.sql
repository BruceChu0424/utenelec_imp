-- V299: 结算方式主档编号命名空间注册。
--
-- 背景：销售单据编辑页新增「结算方式内联新增」（MasterCodePrefix.SETTLEMENT='JS'，
-- settlement_methods 表），但全局业务标识注册表（V279）未登记该命名空间，
-- BusinessIdentifierRegistryMigrationContractTest 守卫拦截。
-- 自包含：仅注册命名空间行，不建表不回填。

INSERT INTO business_identifier_namespaces (
    namespace_key, identifier_family, fixed_prefix,
    source_table, identifier_column, discriminator_value)
VALUES
    ('MASTER_SETTLEMENT', 'MASTER', 'JS', 'settlement_methods', 'code', NULL)
ON CONFLICT (namespace_key) DO NOTHING;
