package com.uten.imp.features.finance.statement;

import com.uten.imp.application.port.FinancialAuxiliaryValidationPort;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceAuxiliaryContracts.*;

/** One directory/validation authority shared by journals, openings and party statements. */
@Service
@RequiredArgsConstructor
public class FinanceAuxiliaryService implements FinancialAuxiliaryValidationPort {
    private static final Set<String> ROLES=Set.of("CUSTOMER","SUPPLIER","EMPLOYEE","OTHER");
    private final JdbcTemplate db;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final FinanceDocumentAccessPolicy access;
    private static final String ITEMS="""
            SELECT a.*,CASE a.role WHEN 'CUSTOMER' THEN c.code WHEN 'SUPPLIER' THEN s.code
                   WHEN 'EMPLOYEE' THEN employee.code ELSE party.source_code END AS party_code,
                   CASE a.role WHEN 'CUSTOMER' THEN c.name WHEN 'SUPPLIER' THEN s.name
                   WHEN 'EMPLOYEE' THEN employee.full_name ELSE party.source_name END AS party_name
            FROM finance_auxiliary_items a LEFT JOIN clients c ON a.role='CUSTOMER' AND c.id=a.party_id
            LEFT JOIN suppliers s ON a.role='SUPPLIER' AND s.id=a.party_id
            LEFT JOIN employees employee ON a.role='EMPLOYEE' AND employee.id=a.party_id
            LEFT JOIN finance_auxiliary_parties party ON a.role='OTHER' AND party.id=a.party_id
            """;
    private void readAccess(){CurrentAuthorityGuard.requireAll("finance_report:view");FinanceCompanyReportAccess.require(access);}
    private void writeAccess(){readAccess();CurrentAuthorityGuard.requireAll("payment_style:edit");}
    private void lock(boolean shared){db.query("SELECT "+(shared?"pg_advisory_xact_lock_shared":"pg_advisory_xact_lock")+"(hashtextextended('uten:finance-auxiliary',0))",rs->{});}

    @Transactional(readOnly=true)
    public Map<String,Object> list(String accountCode,String role,String keyword,int page,int size) {
        readAccess();int safeSize=Math.max(1,Math.min(500,size)),safePage=Math.max(1,page);
        var args=new ArrayList<Object>();String where=" WHERE true";
        if(accountCode!=null&&!accountCode.isBlank()){
            where+=" AND EXISTS(SELECT 1 FROM finance_account_auxiliary_bindings b WHERE b.account_code=? AND b.auxiliary_id=a.id)";args.add(accountCode);
        }
        if(role!=null&&!role.isBlank()){requireRole(role);where+=" AND a.role=?";args.add(role);}
        if(keyword!=null&&!keyword.isBlank()) {
            if(keyword.length()>240)throw invalid("辅助项目检索内容过长");
            where+=" AND (a.source_code ILIKE ? ESCAPE '\\' OR a.source_name ILIKE ? ESCAPE '\\')";
            String pattern="%"+keyword.replace("\\","\\\\").replace("%","\\%").replace("_","\\_")+"%";args.add(pattern);args.add(pattern);
        }
        long total=Objects.requireNonNull(db.queryForObject("SELECT count(*) FROM finance_auxiliary_items a"+where,Long.class,args.toArray()));
        args.add(safeSize);args.add((long)(safePage-1)*safeSize);
        var items=db.query(ITEMS+where+" ORDER BY a.source_system,a.role,a.source_code,a.id LIMIT ? OFFSET ?",(rs,n)->new Item(
                rs.getObject("id",UUID.class),rs.getString("source_system"),rs.getString("source_code"),rs.getString("source_name"),rs.getString("role"),
                rs.getObject("party_id",UUID.class),rs.getString("party_code"),rs.getString("party_name"),rs.getString("status"),rs.getLong("row_version"),rs.getString("source_reference")),args.toArray());
        return Map.of("items",items,"page",safePage,"size",safeSize,"total",total,"totalPages",(total+safeSize-1)/safeSize);
    }

    @Transactional
    public Item save(Save input) {
        writeAccess();if(input==null)throw invalid("请填写辅助核算项目");
        String system=bounded(input.sourceSystem(),80,"来源账套"),code=bounded(input.sourceCode(),240,"原项目编号"),name=bounded(input.sourceName(),240,"原项目名称");
        requireRole(input.role());if(input.partyId()!=null)requireParty(input.role(),input.partyId());
        String reference=input.sourceReference()==null?null:bounded(input.sourceReference(),2000,"来源依据");
        tx.bind();lock(false);UUID id=input.id();
        if(id==null) {
            var duplicate=db.queryForList("SELECT id,source_name,party_id,source_reference,status FROM finance_auxiliary_items WHERE source_system=? AND role=? AND source_code=?",system,input.role(),code);
            if(!duplicate.isEmpty()) {
                var old=duplicate.getFirst();
                if(!name.equals(old.get("source_name"))||!Objects.equals(input.partyId(),old.get("party_id"))||!Objects.equals(reference,old.get("source_reference"))||!"ACTIVE".equals(old.get("status")))
                    throw conflict("该账套和类别的原项目编号已存在，请刷新并核对原项目，不能按名称合并");
                id=(UUID)old.get("id");
            } else {
                id=UUID.randomUUID();db.update("INSERT INTO finance_auxiliary_items(id,source_system,source_code,source_name,role,party_id,client_id,supplier_id,employee_id,financial_party_id,source_reference,created_by,updated_by) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                        id,system,code,name,input.role(),input.partyId(),target(input,"CUSTOMER"),target(input,"SUPPLIER"),target(input,"EMPLOYEE"),target(input,"OTHER"),reference,current.requireId(),current.requireId());
            }
        } else {
            if(input.expectedVersion()==null)throw invalid("请先刷新辅助项目版本");
            var before=db.queryForList("SELECT source_system,source_code,source_name,role,party_id,source_reference,row_version FROM finance_auxiliary_items WHERE id=? FOR UPDATE",id);
            if(before.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"辅助项目不存在");
            var old=before.getFirst();
            if(!system.equals(old.get("source_system"))||!code.equals(old.get("source_code"))||!input.role().equals(old.get("role")))
                throw conflict("来源账套、类别和原编号属于项目身份，不能修改为另一个项目");
            if(!Objects.equals(input.partyId(),old.get("party_id"))&&db.queryForObject(
                    "SELECT EXISTS(SELECT 1 FROM finance_gl_entry_allocations WHERE auxiliary_id=?) OR EXISTS(SELECT 1 FROM finance_gl_auxiliary_opening_evidence WHERE auxiliary_id=?)",Boolean.class,id,id))
                throw conflict("辅助项目已有会计分录引用，不能更换业务对象，请走受控更正");
            long version=((Number)old.get("row_version")).longValue();
            boolean replay=version==input.expectedVersion()+1&&name.equals(old.get("source_name"))&&Objects.equals(input.partyId(),old.get("party_id"))&&Objects.equals(reference,old.get("source_reference"));
            if(!replay&&db.update("UPDATE finance_auxiliary_items SET source_name=?,party_id=?,client_id=?,supplier_id=?,employee_id=?,financial_party_id=?,source_reference=?,row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=? AND row_version=?",
                    name,input.partyId(),target(input,"CUSTOMER"),target(input,"SUPPLIER"),target(input,"EMPLOYEE"),target(input,"OTHER"),reference,current.requireId(),id,input.expectedVersion())!=1)throw conflict("辅助项目已变化，请刷新后核对");
        }
        if(input.accountCode()!=null&&!input.accountCode().isBlank()) {
            ensureAccount(input.accountCode());Rule rule=rule(input.accountCode());
            if(!rule.allowedRoles().contains(input.role()))throw invalid("该科目不允许所选辅助项目类别");
            db.update("INSERT INTO finance_account_auxiliary_bindings(account_code,auxiliary_id,created_by) VALUES(?,?,?) ON CONFLICT DO NOTHING",input.accountCode(),id,current.requireId());
        }
        return item(id,false);
    }

    @Transactional
    public Party createParty(PartyInput input) {
        writeAccess();if(input==null)throw invalid("请填写财务往来对象");
        String system=bounded(input.sourceSystem(),80,"来源账套"),code=bounded(input.sourceCode(),240,"原对象编号"),name=bounded(input.sourceName(),240,"原对象名称");
        tx.bind();lock(false);
        var found=db.query("SELECT id,source_system,source_code,source_name,row_version FROM finance_auxiliary_parties WHERE source_system=? AND source_code=?",
                (rs,n)->new Party(rs.getObject(1,UUID.class),rs.getString(2),rs.getString(3),rs.getString(4),rs.getLong(5)),system,code);
        if(!found.isEmpty()) {
            if(!found.getFirst().sourceName().equals(name))throw conflict("原对象编号已存在其他名称，请核对，不能按同名或换名重建");
            return found.getFirst();
        }
        UUID id=UUID.randomUUID();db.update("INSERT INTO finance_auxiliary_parties(id,source_system,source_code,source_name,created_by,updated_by) VALUES(?,?,?,?,?,?)",id,system,code,name,current.requireId(),current.requireId());
        return new Party(id,system,code,name,0);
    }

    @Transactional(readOnly=true)
    public Rule readRule(String accountCode){readAccess();ensureAccount(accountCode);return rule(accountCode);}

    @Transactional
    public Rule saveRule(String accountCode,RuleInput input) {
        writeAccess();if(input==null)throw invalid("请填写科目辅助核算规则");ensureAccount(accountCode);
        if(mandatoryAccount(accountCode)&&!input.required())throw invalid("财务要求应收应付必须设置辅助核算项目，不能关闭");
        var roles=new LinkedHashSet<>(input.allowedRoles()==null?List.<String>of():input.allowedRoles());
        if(roles.isEmpty()||!ROLES.containsAll(roles))throw invalid("请选择有效的辅助项目类别");
        String reference=bounded(input.sourceReference(),2000,"核对依据");tx.bind();lock(false);
        var currentVersion=db.queryForList("SELECT row_version FROM finance_account_auxiliary_rules WHERE account_code=? FOR UPDATE",Long.class,accountCode);
        if(currentVersion.isEmpty()) {
            if(input.expectedVersion()!=-1)throw conflict("辅助规则已变化，请刷新后核对");
            db.update("INSERT INTO finance_account_auxiliary_rules(account_code,required,allowed_roles,source_reference,updated_by) VALUES(?,?,?::text[],?,?)",
                    accountCode,input.required(),"{"+String.join(",",roles)+"}",reference,current.requireId());
        } else if(db.update("UPDATE finance_account_auxiliary_rules SET required=?,allowed_roles=?::text[],source_reference=?,row_version=row_version+1,updated_at=now(),updated_by=? WHERE account_code=? AND row_version=?",
                input.required(),"{"+String.join(",",roles)+"}",reference,current.requireId(),accountCode,input.expectedVersion())!=1)
            throw conflict("辅助规则已变化，请刷新后核对");
        return rule(accountCode);
    }

    @Override @Transactional(readOnly=true,noRollbackFor=ApiException.class)
    public Ref inspect(Selection selection) {
        if(selection==null)throw invalid("辅助核算引用不能为空");ensureAccount(selection.accountCode());requireCurrency(selection.currencyId());
        Rule policy=rule(selection.accountCode());
        if(selection.auxiliaryId()==null) {
            if(policy.required())throw invalid("该应收/应付科目必须设置辅助核算项目");return null;
        }
        Item value=item(selection.auxiliaryId(),false);validateRule(policy,value,false);return ref(value);
    }

    @Override @Transactional(readOnly=true,noRollbackFor=ApiException.class)
    public Ref inspectHistorical(Selection selection){
        if(selection==null)throw invalid("辅助核算引用不能为空");ensureAccount(selection.accountCode());requireCurrency(selection.currencyId());Rule policy=rule(selection.accountCode());
        if(selection.auxiliaryId()==null){if(policy.required())throw invalid("该应收/应付科目缺少原辅助身份");return null;}
        Item value=item(selection.auxiliaryId(),false);
        if(!policy.allowedRoles().contains(value.role()))throw invalid("原辅助项目类别与科目不符");
        return ref(value);
    }

    @Override @Transactional
    public List<Ref> validateForPosting(List<Selection> selections) {
        if(selections==null||selections.size()>5000)throw invalid("辅助核算校验最多5000条");
        lock(true);var result=new ArrayList<Ref>();var accounts=new HashMap<String,Rule>();var currencies=new HashSet<UUID>();var items=new HashMap<UUID,Item>();
        for(var selection:selections) {
            if(selection==null)throw invalid("辅助核算引用不能为空");
            Rule policy=accounts.computeIfAbsent(selection.accountCode(),code->{ensureAccount(code);return rule(code);});
            if(currencies.add(selection.currencyId()))requireCurrency(selection.currencyId());
            if(selection.auxiliaryId()==null) {
                if(policy.required())throw invalid("该应收/应付科目必须设置辅助核算项目："+selection.accountCode());
                result.add(null);continue;
            }
            Item value=items.computeIfAbsent(selection.auxiliaryId(),id->item(id,true));validateRule(policy,value,true);result.add(ref(value));
        }
        return Collections.unmodifiableList(result);
    }

    @Override @Transactional(readOnly=true,noRollbackFor=ApiException.class)
    public Ref resolveImported(String accountCode,String sourceSystem,String role,String sourceCode,UUID currencyId) {
        requireRole(role);var ids=db.queryForList("SELECT id FROM finance_auxiliary_items WHERE source_system=? AND role=? AND source_code=?",UUID.class,
                bounded(sourceSystem,80,"来源账套"),role,bounded(sourceCode,240,"原项目编号"));
        if(ids.size()!=1)throw conflict("未找到唯一的原辅助项目编号，请先维护辅助核算目录；不能按名称猜配");
        return inspect(new Selection(accountCode,ids.getFirst(),currencyId));
    }

    @Override @Transactional(readOnly=true,noRollbackFor=ApiException.class)
    public Ref resolveNative(String accountCode,String role,UUID partyId,UUID currencyId) {
        requireRole(role);if(partyId==null)throw invalid("业务往来对象不能为空");
        var ids=db.queryForList("SELECT a.id FROM finance_auxiliary_items a JOIN finance_account_auxiliary_bindings b ON b.auxiliary_id=a.id WHERE b.account_code=? AND a.role=? AND a.party_id=? AND a.status='ACTIVE'",UUID.class,accountCode,role,partyId);
        if(ids.isEmpty())ids=db.queryForList("SELECT id FROM finance_auxiliary_items WHERE role=? AND party_id=? AND status='ACTIVE'",UUID.class,role,partyId);
        if(ids.size()!=1)throw conflict(ids.isEmpty()?"该业务对象尚未对应财务辅助项目，请先核对目录":"该业务对象对应多个财务辅助项目，请明确选择科目下的原项目编号");
        return inspect(new Selection(accountCode,ids.getFirst(),currencyId));
    }

    private Rule rule(String code) {
        var values=db.query("SELECT required,allowed_roles,source_reference,row_version FROM finance_account_auxiliary_rules WHERE account_code=?",
                (rs,n)->new Rule(code,rs.getBoolean(1),Arrays.asList((String[])rs.getArray(2).getArray()),rs.getString(3),rs.getLong(4),true),code);
        if(!values.isEmpty())return values.getFirst();
        List<String> roles=code.startsWith("1122")||code.startsWith("2203")?List.of("CUSTOMER"):
                code.startsWith("2202")||code.startsWith("1123")?List.of("SUPPLIER"):List.of("CUSTOMER","SUPPLIER","EMPLOYEE","OTHER");
        boolean required=mandatoryAccount(code);
        return new Rule(code,required,roles,"财务要求应收应付设置辅助核算；未单独设置的原科目按已提供科目组继承",-1,false);
    }
    private Item item(UUID id,boolean locked) {
        var values=db.query(ITEMS+" WHERE a.id=?"+(locked?" FOR SHARE OF a":""),(rs,n)->new Item(
                rs.getObject("id",UUID.class),rs.getString("source_system"),rs.getString("source_code"),rs.getString("source_name"),rs.getString("role"),
                rs.getObject("party_id",UUID.class),rs.getString("party_code"),rs.getString("party_name"),rs.getString("status"),rs.getLong("row_version"),rs.getString("source_reference")),id);
        if(values.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"辅助核算项目不存在");return values.getFirst();
    }
    private void validateRule(Rule rule,Item item,boolean posting) {
        if(!"ACTIVE".equals(item.status()))throw conflict("辅助项目已停用，不能用于新的核算");
        if(!rule.allowedRoles().contains(item.role()))throw invalid("辅助项目类别与科目不符");
        if(posting&&(item.partyId()==null||item.partyName()==null))throw conflict("辅助项目尚未对应有效业务对象，只能保留草稿");
    }
    private void ensureAccount(String code){if(code==null||db.queryForObject("SELECT count(*) FROM finance_chart_codes WHERE code=?",Integer.class,code)!=1)throw invalid("财务科目代码尚未维护");}
    private void requireCurrency(UUID id){if(id==null||db.queryForObject("SELECT count(*) FROM currencies WHERE id=?",Integer.class,id)!=1)throw invalid("请选择已核验的币别");}
    private void requireParty(String role,UUID id) {
        String table=switch(role){case "CUSTOMER"->"clients";case "SUPPLIER"->"suppliers";case "EMPLOYEE"->"employees";default->"finance_auxiliary_parties";};
        if(db.queryForObject("SELECT count(*) FROM "+table+" WHERE id=?",Integer.class,id)!=1)throw invalid("所选业务对象与辅助类别不对应");
    }
    private static Ref ref(Item item){return new Ref(item.id(),item.role(),item.partyId(),item.sourceSystem(),item.sourceCode(),item.sourceName());}
    private static boolean mandatoryAccount(String code){return List.of("1122","2202","1123","2203","1221","2241","2701").stream().anyMatch(code::startsWith);}
    private static UUID target(Save input,String role){return role.equals(input.role())?input.partyId():null;}
    private static void requireRole(String role){if(role==null||!ROLES.contains(role))throw invalid("辅助类别应为客户、供应商、员工或其他往来");}
    private static String bounded(String value,int max,String label){if(value==null||value.isBlank()||value.length()>max)throw invalid(label+"不能为空且不得超过"+max+"字");return value.strip();}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
