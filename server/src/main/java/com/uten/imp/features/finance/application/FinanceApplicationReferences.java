package com.uten.imp.features.finance.application;
import com.uten.imp.common.web.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;

/** Purpose-limited references. Source facts remain native; no UUID or same-name guess inputs. */
@Service @RequiredArgsConstructor
public class FinanceApplicationReferences {
    private final JdbcTemplate db;private final FinanceApplicationRoles roles;
    @Transactional(readOnly=true) public Map<String,Object> references(){var actor=roles.staff();if(!roles.has(actor,FinanceApplicationPermissions.VIEW)&&!roles.has(actor,FinanceApplicationPermissions.APPLY)&&!roles.has(actor,"expense:apply")&&!roles.has(actor,"payroll:generate")&&!roles.has(actor,FinanceApplicationPermissions.SETTINGS))throw new ApiException(ErrorCode.FORBIDDEN);var out=new LinkedHashMap<String,Object>();
        out.put("currencies",db.queryForList("SELECT id,code,name,is_base_currency AS \"baseCurrency\" FROM currencies WHERE NOT is_deleted AND status='使用' ORDER BY code,id"));
        out.put("departments",roles.has(actor,FinanceApplicationPermissions.SETTINGS)?db.queryForList("SELECT id,name FROM departments WHERE NOT is_deleted ORDER BY path,id"):List.of());
        if(roles.has(actor,FinanceApplicationPermissions.EXECUTE))out.put("accounts",db.queryForList("SELECT id,code,name,currency_id AS \"currencyId\" FROM accounts WHERE NOT is_deleted AND status='使用' ORDER BY code,id"));
        return out;
    }
    @Transactional(readOnly=true) public Map<String,Object> sources(String kind,String search,UUID supplier,UUID currency){var actor=roles.staff();String term=Objects.toString(search,"").strip();if(term.length()>100)throw new ApiException(ErrorCode.VALIDATION_FAILED,"查询内容过长");String like="%"+term.replace("!","!!").replace("%","!%").replace("_","!_")+"%";List<Map<String,Object>> rows;
        switch(kind){
            case "EXPENSE_CLAIM"->{roles.require(actor,"expense:apply");rows=db.queryForList("SELECT id,claim_no AS code,title AS name,total_amount::text AS amount,status FROM expense_claims WHERE NOT is_deleted AND applicant_id=fn_canonical_employee_identity(?) AND status IN('DRAFT','REJECTED') AND (claim_no ILIKE ? ESCAPE '!' OR title ILIKE ? ESCAPE '!') ORDER BY created_at DESC,id LIMIT 101",actor.getEmployeeId(),like,like);}
            case "TRAVEL_APPLICATION"->{roles.require(actor,"expense:apply");rows=db.queryForList("""
                SELECT id,code,name,"sourceKind" FROM (
                 SELECT id,application_no AS code,title AS name,'FINANCE_APPLICATION'::text AS "sourceKind",created_at
                  FROM finance_applications WHERE applicant_id=fn_canonical_employee_identity(?) AND kind='TRAVEL_APPLICATION' AND status='ARCHIVED'
                 UNION ALL
                 SELECT id,application_no AS code,title AS name,'BUSINESS_APPLICATION'::text AS "sourceKind",created_at
                  FROM business_applications WHERE applicant_id=fn_canonical_employee_identity(?) AND kind='TRAVEL' AND status='COMPLETED'
                ) source WHERE code ILIKE ? ESCAPE '!' OR name ILIKE ? ESCAPE '!'
                ORDER BY created_at DESC,"sourceKind",id LIMIT 101
                """,actor.getEmployeeId(),actor.getEmployeeId(),like,like);}
            case "PAYROLL_BATCH"->{roles.require(actor,"payroll:generate");rows=db.queryForList("SELECT id,concat(payroll_year,'-',lpad(payroll_month::text,2,'0')) AS code,concat(headcount,'人 工资批次') AS name,net_income::text AS amount,status FROM payroll_batches WHERE status IN('APPROVED','PUBLISHED') AND (? OR generated_by=fn_canonical_employee_identity(?)) AND concat(payroll_year,'-',lpad(payroll_month::text,2,'0')) ILIKE ? ESCAPE '!' ORDER BY payroll_year DESC,payroll_month DESC,id LIMIT 101",roles.has(actor,"payroll:view:all"),actor.getEmployeeId(),like);}
            case "SUPPLIER"->{roles.require(actor,FinanceApplicationPermissions.APPLY);rows=db.queryForList("SELECT id,code,name FROM suppliers WHERE NOT is_deleted AND status='使用' AND (code ILIKE ? ESCAPE '!' OR name ILIKE ? ESCAPE '!') ORDER BY code,id LIMIT 101",like,like);}
            case "SUPPLIER_AP"->{roles.require(actor,"ar_ap_ledger:view","finance:view:all");if(supplier==null||currency==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"请先选择供应商和明确原币");rows=db.queryForList("SELECT id,bill_no AS code,concat(bill_date,' ',business_type) AS name,amount_balance_original::text AS amount FROM ar_ap_ledger WHERE NOT is_deleted AND status=1 AND direction='AP' AND open_item_kind='PAYABLE' AND supplier_id=? AND currency_id=? AND amount_balance_original>0 AND bill_no ILIKE ? ESCAPE '!' ORDER BY bill_date,id LIMIT 101",supplier,currency,like);}
            default->throw new ApiException(ErrorCode.VALIDATION_FAILED,"原始来源类型不存在");
        }
        return Map.of("items",rows.size()>100?rows.subList(0,100):rows,"more",rows.size()>100);
    }
}
