-- Audit exports retain their original role/actor authority, independently of business owner policies.
-- The previous migration bytes and all original audit/permission facts remain unchanged.
ALTER TABLE read_scope_domains DROP CONSTRAINT read_scope_domains_domain_check;
ALTER TABLE read_scope_domains ADD CONSTRAINT read_scope_domains_domain_check CHECK (domain IN (
    'sales','purchase','subcontract','production','stock','finance','client','supplier',
    'master_goods','master_account','master_currency','master_color','master_unit','master_mould','master_warehouse','master_settlement_method',
    'audit'));
INSERT INTO read_scope_domains(domain) VALUES ('audit');
