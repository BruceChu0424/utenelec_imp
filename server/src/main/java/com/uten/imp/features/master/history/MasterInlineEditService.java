package com.uten.imp.features.master.history;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.account.AccountService;
import com.uten.imp.features.master.account.dto.AccountSaveRequest;
import com.uten.imp.features.master.color.ColorService;
import com.uten.imp.features.master.color.dto.ColorSaveRequest;
import com.uten.imp.features.master.currency.CurrencyService;
import com.uten.imp.features.master.currency.dto.CurrencySaveRequest;
import com.uten.imp.features.master.mould.MouldService;
import com.uten.imp.features.master.mould.dto.MouldSaveRequest;
import com.uten.imp.features.master.unit.UnitService;
import com.uten.imp.features.master.unit.dto.UnitSaveRequest;
import com.uten.imp.features.master.referencemethod.ReferenceMethodService;
import com.uten.imp.features.master.referencemethod.SettlementMethodTermsRequest;
import com.uten.imp.features.master.client.ClientService;
import com.uten.imp.features.master.client.dto.ClientSaveRequest;
import com.uten.imp.features.master.supplier.SupplierService;
import com.uten.imp.features.master.supplier.dto.SupplierSaveRequest;
import com.uten.imp.features.master.warehouse.WarehouseService;
import com.uten.imp.features.master.warehouse.dto.WarehouseSaveRequest;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.validation.Validator;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.*;

/** A narrow CAS adapter around the existing full-form commands. */
@Service
@RequiredArgsConstructor
@PreAuthorize("isAuthenticated()")
public class MasterInlineEditService {
    private final EntityManager em;
    private final ObjectMapper mapper;
    private final Validator validator;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ColorService colors;
    private final UnitService units;
    private final CurrencyService currencies;
    private final MouldService moulds;
    private final AccountService accounts;
    private final ReferenceMethodService referenceMethods;
    private final ClientService clients;
    private final SupplierService suppliers;
    private final WarehouseService warehouses;

    private record Domain(String table,String permission,Set<String> fields,Class<?> request) {}
    private static final Map<String,Domain> DOMAINS=Map.of(
        "colors",new Domain("colors","color",Set.of("name","status","remark"),ColorSaveRequest.class),
        "units",new Domain("units","unit",Set.of("name","status","measurementDimension","massUnitCode"),UnitSaveRequest.class),
        "currencies",new Domain("currencies","currency",Set.of("name","status","exchangeRate"),CurrencySaveRequest.class),
        "moulds",new Domain("moulds","mould",Set.of("name","status","categoryId","mnumber","qty","tqty","mstatus","manufacturer","place","keeper","departmentId","keeperId","remark"),MouldSaveRequest.class),
        "accounts",new Domain("accounts","account",Set.of("name","bankAccountNo","accountType","currencyId"),AccountSaveRequest.class),
        "reference-methods",new Domain("settlement_methods","settlement_method",Set.of("name","termsBase","dueRule","defaultDueDays","fixedDayOfMonth","monthsAhead"),SettlementMethodTermsRequest.class),
        "clients",new Domain("clients","client",Set.of("name","nameEn","fullName","clientRank","region","placeId","legalPerson","linkman","mobile","phone","phone2","fax","postcode","address","email","website","shipVia","shipAddress","bank","bankAccount","taxId","tday","creditFloor","defaultSettlementMethodId","defaultCurrencyId","defaultShipmentPolicy","status","remark"),ClientSaveRequest.class),
        "suppliers",new Domain("suppliers","supplier",Set.of("name","description","place","legalPerson","linkman","mobile","phone","phone2","fax","postcode","address","email","website","shipVia","shipAddress","bank","bankAccount","taxId","tday","defaultSettlementMethodId","defaultCurrencyId","defaultTaxRate","status","remark"),SupplierSaveRequest.class),
        "warehouses",new Domain("warehouses","warehouse",Set.of("code","name","location","remark","accountable","workshopDepartmentId","defective","status"),WarehouseSaveRequest.class));
    private static final Set<String> PARTY_BASELINE=Set.of("categoryId","code","name","fullName","clientRank","region","placeId","description","place","legalPerson","linkman","mobile","phone","phone2","fax","postcode","address","email","website","shipVia","shipAddress","bank","bankAccount","taxId","tday","credit","initTotal","creditFloor","status","remark","version");

    @Transactional
    public Object patch(String entityType,UUID id,Map<String,Object> expected,Map<String,Object> changes) {
        Domain domain=DOMAINS.get(entityType);
        if(domain==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"不支持的表格编辑类型");
        var user=currentUser.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED,"当前登录状态无效"));
        if(user.getEmployeeId()==null||user.isVisitor()||!user.isAccountNonLocked()||user.isMustChangePassword()||user.getImpersonatedBy()!=null)
            throw new ApiException(ErrorCode.FORBIDDEN,"当前账号不能编辑资料，请核对登录状态");
        CurrentAuthorityGuard.requireAll(domain.permission()+":view");
        boolean clientFinancial = entityType.equals("clients") && changes != null && !changes.isEmpty()
                && com.uten.imp.features.master.client.ClientFinancialPolicy.FINANCIAL_FIELDS.containsAll(changes.keySet());
        if (entityType.equals("clients") && changes != null && changes.keySet().stream()
                .anyMatch(com.uten.imp.features.master.client.ClientFinancialPolicy.FINANCIAL_FIELDS::contains))
            com.uten.imp.features.master.client.ClientFinancialPolicy.requireAuthority();
        // A financial-only client patch carries no ordinary edit scope: the finance
        // guard above already authorized exactly those fields. The edit check always
        // executes; only its required permission set differs by patch shape.
        CurrentAuthorityGuard.requireAll(clientFinancial ? new String[0]
                : new String[]{domain.permission() + ":edit"});
        boolean versioned=entityType.equals("clients")||entityType.equals("suppliers");
        if(changes==null||changes.isEmpty()||expected==null||!domain.fields().containsAll(changes.keySet())
            ||(versioned?!expected.containsKey("version"):!expected.keySet().containsAll(changes.keySet())))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"只能编辑允许的资料字段，并须提供每个字段的原值");
        tx.bind();
        if(entityType.equals("clients")) {
            var client = clients.detail(id);
            if(clientFinancial ? !client.isFinancialWritable() : !client.isWritable()) throw new ApiException(ErrorCode.NOT_FOUND,"客户不存在");
        }
        if(entityType.equals("accounts")) {
            com.uten.imp.application.concurrency.PaymentStyleHierarchyLock.lock(em);
            em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended('ACCOUNT_MASTER_POPULATION',0))").getSingleResult();
        }
        try {
            if(em.createNativeQuery("SELECT id FROM "+domain.table()+" WHERE id=:id AND NOT is_deleted FOR UPDATE NOWAIT").setParameter("id",id).getResultList().isEmpty())
                throw new ApiException(ErrorCode.NOT_FOUND,"资料不存在");
        } catch(ApiException failure) {throw failure;}
        catch(RuntimeException failure) {var error=new ApiException(ErrorCode.CONFLICT,"资料正在由其他操作更新，请刷新后重试");error.initCause(failure);throw error;}
        if(versioned)em.clear();
        Object detail=switch(entityType) {case "colors"->colors.detail(id);case "units"->units.detail(id);case "currencies"->currencies.detail(id);case "moulds"->moulds.detail(id);case "accounts"->accounts.detail(id);case "reference-methods"->settlementTerms(id);case "clients"->clients.detail(id);case "suppliers"->suppliers.detail(id);case "warehouses"->warehouses.detail(id);default->throw new IllegalStateException();};
        ObjectNode actual=mapper.valueToTree(detail);
        if(entityType.equals("clients")&&!actual.path(clientFinancial ? "financialWritable" : "writable").asBoolean())throw new ApiException(ErrorCode.NOT_FOUND,"客户不存在");
        if(versioned) {
            JsonNode version=mapper.valueToTree(expected.get("version"));
            if(!version.isIntegralNumber()||!version.canConvertToLong())throw new ApiException(ErrorCode.VALIDATION_FAILED,"须提供原资料版本");
            if(!equal(actual.get("version"),version))throw new ApiException(ErrorCode.CONFLICT,"该行已有后续修改，请刷新后重新编辑；没有覆盖任何修改");
        } else for(String key:changes.keySet())if(!equal(actual.get(key),mapper.valueToTree(expected.get(key))))
                throw new ApiException(ErrorCode.CONFLICT,"该行的“"+key+"”已被其他操作修改，请刷新后重新编辑；没有覆盖任何修改");
        // Keep every current form value, including hidden measurement and
        // category references. Only the changed fields came from the list.
        Set<String> requestFields=new HashSet<>(domain.fields());
        if(!entityType.equals("reference-methods"))requestFields.add("code");
        if(entityType.equals("accounts"))requestFields.addAll(Set.of("styleId","styleLegacyId","parentLegacyId","status"));
        // Omitted workshop references preserve the current warehouse assignment;
        // explicit null remains the existing command's request to clear it.
        if(entityType.equals("warehouses")&&!changes.containsKey("workshopDepartmentId"))requestFields.remove("workshopDepartmentId");
        ObjectNode merged=mapper.createObjectNode();
        if(versioned)requestFields=new HashSet<>(PARTY_BASELINE);
        for(String key:requestFields)if(actual.has(key))merged.set(key,actual.get(key));
        changes.forEach((key,value)->merged.set(key,mapper.valueToTree(value)));
        if(entityType.equals("units")&&changes.containsKey("measurementDimension")
            &&!"MASS".equalsIgnoreCase(merged.path("measurementDimension").asText()))merged.putNull("massUnitCode");
        if(entityType.equals("reference-methods")&&changes.containsKey("dueRule")
            &&!"FIXED_DAY_OF_MONTH".equals(merged.path("dueRule").asText()))merged.putNull("fixedDayOfMonth");
        Object request;
        try {request=mapper.treeToValue(merged,domain.request());}
        catch(Exception failure) {throw new ApiException(ErrorCode.VALIDATION_FAILED,"编辑值格式不正确，请检查数值或选择项");}
        var violations=validator.validate(request);
        if(!violations.isEmpty())throw new ApiException(ErrorCode.VALIDATION_FAILED,violations.iterator().next().getMessage());
        return switch(entityType) {
            case "colors"->colors.update(id,(ColorSaveRequest)request);
            case "units"->units.update(id,(UnitSaveRequest)request);
            case "currencies"->currencies.update(id,(CurrencySaveRequest)request);
            case "moulds"->moulds.update(id,(MouldSaveRequest)request);
            case "accounts"->accounts.update(id,(AccountSaveRequest)request);
            case "reference-methods"->referenceMethods.updateTerms(id,(SettlementMethodTermsRequest)request);
            case "clients"->clients.update(id,(ClientSaveRequest)request);
            case "suppliers"->suppliers.update(id,(SupplierSaveRequest)request);
            case "warehouses"->warehouses.update(id,(WarehouseSaveRequest)request);
            default->throw new IllegalStateException();
        };
    }
    private JsonNode settlementTerms(UUID id) {
        Object value=em.createNativeQuery("""
            SELECT CAST(jsonb_build_object('name',name,'termsBase',terms_base,'dueRule',due_rule,
             'defaultDueDays',default_due_days,'fixedDayOfMonth',fixed_day_of_month,'monthsAhead',months_ahead) AS text)
            FROM settlement_methods WHERE id=:id
            """).setParameter("id",id).getSingleResult();
        try {return mapper.readTree(value.toString());}catch(Exception failure){throw new IllegalStateException(failure);}
    }
    private static boolean equal(JsonNode a,JsonNode b) {
        if(a==null||a.isNull())return b==null||b.isNull();
        if(a.isNumber()&&b!=null&&b.isNumber())return a.decimalValue().compareTo(b.decimalValue())==0;
        if(a.isNumber()&&b!=null&&b.isTextual()) {
            try{return a.decimalValue().compareTo(new java.math.BigDecimal(b.asText()))==0;}catch(NumberFormatException ignored){return false;}
        }
        return a.equals(b);
    }
}
