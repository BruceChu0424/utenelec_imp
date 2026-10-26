package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.*;

/** Versions read authorization, never business data freshness or a browser session.
 * Call through the Spring proxy for each new publication/checkpoint; no request-local cache is consulted. */
@Service
public class ReadScopeVersionAuthority {
    private static final Set<String> DOMAINS = Set.of("sales", "purchase", "subcontract", "production", "stock", "finance", "client", "supplier",
            "master_goods", "master_account", "master_currency", "master_color", "master_unit", "master_mould", "master_warehouse", "master_settlement_method", "audit",
            "native_feature","native_sales_owner","native_purchase_owner","native_subcontract_owner","native_production_owner",
            "native_fqc_records","native_workshop_tasks","native_warehouse_tasks");
    private final NamedParameterJdbcTemplate jdbc;
    private final SubmitterPrincipalRestorer restorer;
    private final OwnerVisibility owners;
    private final GoodsReadScopePolicy goodsReadScope;
    public record DatasetRealm(UUID datasetId,long resetGeneration) { }
    @org.springframework.beans.factory.annotation.Autowired(required=false)
    private org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.TaskAudiencePort> taskAudience;
    @org.springframework.beans.factory.annotation.Autowired(required=false)
    private org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.SubcontractDocumentReadAccessPort> subcontractAccess;
    @org.springframework.beans.factory.annotation.Autowired(required=false)
    private org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.ProductionDocumentReadScopePort> productionAccess;
    @org.springframework.beans.factory.annotation.Autowired(required=false)
    private org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.ProductionQualityPoolAccessPort> qualityAccess;
    @org.springframework.beans.factory.annotation.Autowired(required=false)
    private org.springframework.beans.factory.ObjectProvider<ProductionWorkshopReadScopePolicy> workshopAccess;
    @org.springframework.beans.factory.annotation.Autowired(required=false)
    private org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.WarehouseTaskScopePort> warehouseAccess;

    public ReadScopeVersionAuthority(NamedParameterJdbcTemplate jdbc, SubmitterPrincipalRestorer restorer, OwnerVisibility owners) {
        this(jdbc, restorer, owners, new GoodsReadScopePolicy(owners));
    }
    @org.springframework.beans.factory.annotation.Autowired
    public ReadScopeVersionAuthority(NamedParameterJdbcTemplate jdbc, SubmitterPrincipalRestorer restorer,
                                     OwnerVisibility owners, GoodsReadScopePolicy goodsReadScope) {
        this.jdbc = jdbc; this.restorer = restorer; this.owners = owners; this.goodsReadScope = goodsReadScope;
    }

    @Transactional(readOnly = true, propagation = Propagation.REQUIRES_NEW, isolation = Isolation.REPEATABLE_READ, timeout = 15)
    public String scopeFor(String domain, AuthUser suppliedSubject) {
        return scopeFor(domain,suppliedSubject,false);
    }

    @Transactional(readOnly = true, propagation = Propagation.REQUIRES_NEW, isolation = Isolation.REPEATABLE_READ, timeout = 15)
    public String scopeFor(String domain, AuthUser suppliedSubject, boolean businessTasks) {
        if (domain == null || !DOMAINS.contains(domain)) throw new ApiException(ErrorCode.VALIDATION_FAILED, "读取范围类型无效");
        if (suppliedSubject == null) throw new ApiException(ErrorCode.UNAUTHORIZED);
        if (suppliedSubject.getId() == null) throw changed();
        DatasetRealm realm=datasetRealm();
        // Function permissions belong to the owning Controller/Service, including
        // independent account-flow and where-used families below the same URL prefix.
        SubmitterPrincipalRestorer.AuthorizationStamps stamps;
        AuthUser actual;
        try {
            stamps = restorer.currentStamps(suppliedSubject.getId()).orElseThrow(() -> changed());
            actual = restorer.restore(suppliedSubject.getId(), stamps.authVersion(), stamps.authorizationEpoch());
        } catch (SubmitterPrincipalRestorer.PrincipalChangedException drift) { throw changed(); }
        if (suppliedSubject.isVisitor() || suppliedSubject.isMustChangePassword() || !suppliedSubject.isAccountNonLocked()
                || !Objects.equals(suppliedSubject.getEmployeeId(), actual.getEmployeeId())
                || suppliedSubject.isSuperAdmin() != actual.isSuperAdmin()
                || !actual.getPermissions().containsAll(suppliedSubject.getPermissions())) throw changed();

        String generationDomain="native_sales_owner".equals(domain)?"sales":domain;
        Long generation = jdbc.queryForObject("SELECT generation FROM read_scope_generations WHERE domain=:domain",
                Map.of("domain", generationDomain), Long.class);
        if (generation == null || generation < 0) throw new ApiException(ErrorCode.PRIMARY_UNAVAILABLE, "读取范围版本不可用");
        var previous = SecurityContextHolder.getContext();
        AuthUser effective=businessTasks?required(taskAudience).freshTaskSubject(suppliedSubject):suppliedSubject;
        if(effective==null||!Objects.equals(effective.getId(),suppliedSubject.getId())
                ||!Objects.equals(effective.getEmployeeId(),suppliedSubject.getEmployeeId())
                ||!suppliedSubject.getPermissions().containsAll(effective.getPermissions())
                ||(businessTasks&&effective.isSuperAdmin()))throw changed();
        var context = SecurityContextHolder.createEmptyContext();
        context.setAuthentication(new UsernamePasswordAuthenticationToken(effective, null, effective.getAuthorities()));
        SecurityContextHolder.setContext(context);
        try {
            // These are the exact read authorities used by the current report/dictionary owners.
            // The other four report families and supplier dictionary currently have company-level feature access;
            // warehouse task ownership and customer-master ACLs must not be imposed on those different contracts.
            OwnerVisibility.OwnerScope scope = switch (domain) {
                case "sales", "native_sales_owner" -> owners.evaluate("sales", "sales:view:all");
                case "native_purchase_owner" -> owners.evaluate("purchase", "purchase:view:all");
                case "finance" -> owners.evaluate("finance", "finance:view:all");
                case "client" -> owners.evaluate("client", "client:view:all");
                case "master_goods" -> goodsReadScope.versionedReadScope();
                case "native_subcontract_owner" -> required(subcontractAccess).scope();
                case "native_production_owner" -> required(productionAccess).scope();
                case "native_fqc_records" -> required(qualityAccess).canAccessQualityPool()?null:required(productionAccess).scope();
                default -> null;
            };
            MessageDigest hash = digest();
            atom(hash, "read-scope-v2"); atom(hash, realm.datasetId()); atom(hash, realm.resetGeneration()); atom(hash, domain);
            atom(hash, suppliedSubject.getId()); atom(hash, suppliedSubject.getEmployeeId());
            atom(hash, effective.isSuperAdmin()); atom(hash, suppliedSubject.getImpersonatedBy());
            atom(hash, stamps.authVersion()); atom(hash, stamps.authorizationEpoch()); atom(hash, generation);
            var permissions = new TreeSet<>(effective.getPermissions());
            atom(hash, permissions.size()); permissions.forEach(permission -> atom(hash, permission));
            atom(hash, scope == null ? "FEATURE" : "OWNER");
            if (scope != null) {
                atom(hash, scope.seeAll());
                List<String> visible = scope.seeAll() ? List.of()
                        : scope.visibleOwners().stream().map(UUID::toString).sorted().toList();
                atom(hash, visible.size()); visible.forEach(owner -> atom(hash, owner));
            }
            if(domain.startsWith("native_")) {
                atom(hash,businessTasks);
                if("native_fqc_records".equals(domain))atom(hash,scope==null?"QUALITY_POOL":"PLAN_OWNER");
                if("native_workshop_tasks".equals(domain)) {
                    var assignment=required(workshopAccess).snapshot(effective);
                    atom(hash,"WORKSHOP_ASSIGNMENT");atom(hash,assignment.all());atom(hash,assignment.responsibleEmployee());
                    uuids(hash,assignment.workshops());
                }
                if("native_warehouse_tasks".equals(domain)) {
                    var access=required(warehouseAccess).freshAccess(effective.getId(),businessTasks);
                    if(access==null)throw new ApiException(ErrorCode.PRIMARY_UNAVAILABLE,"仓库读取范围不可用");
                    atom(hash,"WAREHOUSE_UNIVERSE");atom(hash,access.role());atom(hash,access.warehouseMember());
                    uuids(hash,access.keeperWarehouseIds());atom(hash,access.defaultScope().active());
                    atom(hash,access.defaultScope().includeUnassigned());uuids(hash,access.defaultScope().warehouseIds());
                }
            }
            return HexFormat.of().formatHex(hash.digest());
        } finally { SecurityContextHolder.setContext(previous); }
    }

    private static ApiException changed() {
        return new ApiException(ErrorCode.READ_SCOPE_CHANGED, "身份或可见范围已变化，请重新读取");
    }
    private static MessageDigest digest() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
    }
    private static <T> T required(org.springframework.beans.factory.ObjectProvider<T> provider) {
        T value=provider==null?null:provider.getIfAvailable();
        if(value==null)throw new ApiException(ErrorCode.PRIMARY_UNAVAILABLE,"读取范围权威不可用");
        return value;
    }
    private DatasetRealm datasetRealm() {
        try {
            DatasetRealm realm=jdbc.queryForObject("SELECT business_dataset_id,business_reset_generation FROM authorization_state WHERE singleton_id=1",
                    Map.of(),(result,row)->{
                        long generation=result.getLong("business_reset_generation");
                        if(result.wasNull())return null;
                        return new DatasetRealm(result.getObject("business_dataset_id",UUID.class),generation);
                    });
            if(realm==null||realm.datasetId()==null||realm.resetGeneration()<0)
                throw new ApiException(ErrorCode.PRIMARY_UNAVAILABLE,"数据集读取范围信息不可用");
            return realm;
        } catch(org.springframework.dao.DataAccessException unavailable) {
            throw new ApiException(ErrorCode.PRIMARY_UNAVAILABLE,"数据集读取范围信息不可用");
        }
    }
    private static void uuids(MessageDigest hash,Collection<UUID> values) {
        var ids=values.stream().map(UUID::toString).sorted().toList();atom(hash,ids.size());ids.forEach(id->atom(hash,id));
    }
    private static void atom(MessageDigest hash, Object value) {
        byte[] bytes = Objects.toString(value, "").getBytes(StandardCharsets.UTF_8);
        hash.update(ByteBuffer.allocate(Integer.BYTES).putInt(bytes.length).array()); hash.update(bytes);
    }
}
