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
    /** Legacy suggestion contract remains capped; full-list clients use sourcesPage. */
    @Transactional(readOnly=true)
    public Map<String,Object> sources(String kind,String search,UUID supplier,UUID currency){
        var query=sourceQuery(kind,search,supplier,currency);
        var rows=db.queryForList(query.sql()+" ORDER BY "+query.order()+" LIMIT 101",query.args());
        rows=publicRows(rows);
        return Map.of("items",rows.size()>100?rows.subList(0,100):rows,"more",rows.size()>100);
    }

    @Transactional(readOnly=true)
    public PageResponse<Map<String,Object>> sourcesPage(String kind,String search,UUID supplier,UUID currency,int page,int size){
        var query=sourceQuery(kind,search,supplier,currency);
        page=Math.max(1,page);size=Math.max(1,Math.min(Pageables.MAX_PAGE_SIZE,size));
        long total=db.queryForObject("SELECT count(*) FROM ("+query.sql()+") source_count",Long.class,query.args());
        var parameters=new ArrayList<>(Arrays.asList(query.args()));parameters.add(size);parameters.add((long)(page-1)*size);
        var rows=db.queryForList(query.sql()+" ORDER BY "+query.order()+" LIMIT ? OFFSET ?",parameters.toArray());
        return new PageResponse<>(publicRows(rows),page,size,total,(int)((total+size-1)/size));
    }

    /** Both protocols share the original eligibility before count/limit. */
    private SourceQuery sourceQuery(String kind,String search,UUID supplier,UUID currency){
        var actor=roles.staff();String term=Objects.toString(search,"").strip();
        if(term.length()>100)throw new ApiException(ErrorCode.VALIDATION_FAILED,"查询内容过长");
        String like="%"+term.replace("!","!!").replace("%","!%").replace("_","!_")+"%";
        if(kind==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"原始来源类型不存在");
        return switch(kind){
            case "EXPENSE_CLAIM"->{
                roles.require(actor,"expense:apply");
                yield new SourceQuery("""
                    SELECT id,claim_no AS code,title AS name,total_amount::text AS amount,status,created_at,
                           currency.currency_name,currency.currency_code
                      FROM expense_claims
                      LEFT JOIN (SELECT min(name) AS currency_name,min(code) AS currency_code FROM currencies
                                   WHERE is_base_currency AND NOT is_deleted HAVING count(*)=1) currency ON true
                     WHERE NOT is_deleted AND applicant_id=fn_canonical_employee_identity(?)
                       AND status IN('DRAFT','REJECTED') AND (claim_no ILIKE ? ESCAPE '!' OR title ILIKE ? ESCAPE '!')
                    ""","created_at DESC,id",new Object[]{actor.getEmployeeId(),like,like});
            }
            case "TRAVEL_APPLICATION"->{
                roles.require(actor,"expense:apply");
                yield new SourceQuery("""
                    SELECT id,code,name,"sourceKind",created_at FROM (
                     SELECT id,application_no AS code,title AS name,'FINANCE_APPLICATION'::text AS "sourceKind",created_at
                      FROM finance_applications WHERE applicant_id=fn_canonical_employee_identity(?) AND kind='TRAVEL_APPLICATION' AND status='ARCHIVED'
                     UNION ALL
                     SELECT id,application_no AS code,title AS name,'BUSINESS_APPLICATION'::text AS "sourceKind",created_at
                      FROM business_applications WHERE applicant_id=fn_canonical_employee_identity(?) AND kind='TRAVEL' AND status='COMPLETED'
                    ) source WHERE code ILIKE ? ESCAPE '!' OR name ILIKE ? ESCAPE '!'
                    ""","created_at DESC,\"sourceKind\",id",new Object[]{actor.getEmployeeId(),actor.getEmployeeId(),like,like});
            }
            case "PAYROLL_BATCH"->{
                roles.require(actor,"payroll:generate");
                yield new SourceQuery("""
                    SELECT id,concat(payroll_year,'-',lpad(payroll_month::text,2,'0')) AS code,
                           concat(headcount,'人 工资批次') AS name,net_income::text AS amount,status,
                           payroll_year,payroll_month,currency.currency_name,currency.currency_code
                      FROM payroll_batches
                      LEFT JOIN (SELECT min(name) AS currency_name,min(code) AS currency_code FROM currencies
                                   WHERE is_base_currency AND status='使用' AND NOT is_deleted HAVING count(*)=1) currency ON true
                     WHERE status IN('APPROVED','PUBLISHED') AND (? OR generated_by=fn_canonical_employee_identity(?))
                       AND concat(payroll_year,'-',lpad(payroll_month::text,2,'0')) ILIKE ? ESCAPE '!'
                    ""","payroll_year DESC,payroll_month DESC,id",new Object[]{roles.has(actor,"payroll:view:all"),actor.getEmployeeId(),like});
            }
            case "SUPPLIER"->{
                roles.require(actor,FinanceApplicationPermissions.APPLY);
                yield new SourceQuery("SELECT id,code,name FROM suppliers WHERE NOT is_deleted AND status='使用' AND (code ILIKE ? ESCAPE '!' OR name ILIKE ? ESCAPE '!')","code,id",new Object[]{like,like});
            }
            case "SUPPLIER_AP"->{
                roles.require(actor,"ar_ap_ledger:view","finance:view:all");
                if(supplier==null||currency==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"请先选择供应商和明确原币");
                yield new SourceQuery("""
                    SELECT ledger.id,ledger.bill_no AS code,concat(ledger.bill_date,' ',ledger.business_type) AS name,
                           ledger.amount_balance_original::text AS amount,ledger.bill_date,
                           currency.name AS currency_name,currency.code AS currency_code
                      FROM ar_ap_ledger ledger LEFT JOIN currencies currency ON currency.id=ledger.currency_id
                     WHERE NOT ledger.is_deleted AND ledger.status=1 AND ledger.direction='AP'
                       AND ledger.open_item_kind='PAYABLE' AND ledger.supplier_id=? AND ledger.currency_id=?
                       AND ledger.amount_balance_original>0 AND ledger.bill_no ILIKE ? ESCAPE '!'
                    ""","bill_date,id",new Object[]{supplier,currency,like});
            }
            default->throw new ApiException(ErrorCode.VALIDATION_FAILED,"原始来源类型不存在");
        };
    }
    private static List<Map<String,Object>> publicRows(List<Map<String,Object>> rows){
        return rows.stream().map(row->{var value=new LinkedHashMap<>(row);value.remove("created_at");value.remove("payroll_year");value.remove("payroll_month");value.remove("bill_date");return (Map<String,Object>)value;}).toList();
    }
    private record SourceQuery(String sql,String order,Object[] args){}
}
