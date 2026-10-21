-- Warehouse records use the same field-CAS editor as the other master data.
-- Capture its real PATCH route under the existing mandatory actor/history lock.
CREATE OR REPLACE FUNCTION fn_master_history_entity(p_path text,p_method text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE WHEN p_method NOT IN ('POST','PUT','PATCH','DELETE') THEN NULL
 WHEN p_method='PATCH' AND p_path ~ '^/api/master/inline-edit/(colors|units|currencies|moulds|accounts|reference-methods|clients|suppliers|warehouses)/[0-9a-fA-F-]{36}$' THEN split_part(p_path,'/',5)
 WHEN p_path ~ '^/api/master/(clients|suppliers|moulds|colors|units|currencies|warehouses|accounts)(/[0-9a-fA-F-]{36}(/status|/warning)?|/batch-status|/batch-delete)?$'
  THEN split_part(p_path,'/',4)
 WHEN p_path ~ '^/api/master/(clients|suppliers)/[0-9a-fA-F-]{36}/(contact-methods|addresses|activity-records)(/[0-9a-fA-F-]{36})?$' THEN split_part(p_path,'/',4)
 WHEN p_path ~ '^/api/master/clients/[0-9a-fA-F-]{36}/ship-addresses(/[0-9a-fA-F-]{36})?$' THEN 'clients'
 WHEN p_path ~ '^/api/master/warehouses/[0-9a-fA-F-]{36}/keepers$' THEN 'warehouses'
 WHEN p_path ~ '^/api/master/clients/([0-9a-fA-F-]{36}/access|access/batch)$' THEN 'clients'
 WHEN p_path ~ '^/api/master/(client-categories|supplier-categories|mould-categories)(/[0-9a-fA-F-]{36})?$'
  THEN CASE split_part(p_path,'/',4) WHEN 'client-categories' THEN 'clients' WHEN 'supplier-categories' THEN 'suppliers' ELSE 'moulds' END
 WHEN p_path ~ '^/api/master/payment-styles(/[0-9a-fA-F-]{36})?$' THEN 'payment-styles'
 WHEN p_path ~ '^/api/master/reference-methods/settlement/[0-9a-fA-F-]{36}/terms$' THEN 'reference-methods'
 WHEN p_path='/api/master/reference-methods/settlement' AND p_method='POST' THEN 'reference-methods'
 ELSE NULL END
$$;
