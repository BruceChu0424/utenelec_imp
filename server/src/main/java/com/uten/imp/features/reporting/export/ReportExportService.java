package com.uten.imp.features.reporting.export;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.*;
import com.uten.imp.application.port.MasterReportExportPort;
import com.uten.imp.application.port.WorkbenchReportExportPort;
import com.uten.imp.security.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.nio.file.*;
import java.time.OffsetDateTime;
import java.util.*;

@Service
public class ReportExportService {
    private static final Set<String> DOMAINS=Set.of("sales","purchase","subcontract","production","stock","finance","where_used","master");
    private final ReportExportRepository repository;
    private final SecurityContextCurrentUser users;
    private final SubmitterPrincipalRestorer restorer;
    private final ObjectMapper json;
    private final Path root;
    private final ReportExportBuildIdentity buildIdentity;
    private final ExportRateLimiter rateLimiter;
    private final ReadScopeVersionAuthority readScopes;
    private final MasterReportExportPort master;
    private final WorkbenchReportExportPort workbench;
    private final org.springframework.beans.factory.ObjectProvider<com.uten.imp.common.export.ExportProjectionAccessGuard> projectionAccess;
    @org.springframework.beans.factory.annotation.Autowired
    public ReportExportService(ReportExportRepository repository, SecurityContextCurrentUser users,
            SubmitterPrincipalRestorer restorer,ObjectMapper json,ReportExportBuildIdentity buildIdentity,ExportRateLimiter rateLimiter,
            ReadScopeVersionAuthority readScopes,org.springframework.beans.factory.ObjectProvider<com.uten.imp.common.export.ExportProjectionAccessGuard> projectionAccess,
            MasterReportExportPort master, WorkbenchReportExportPort workbench,
            @Value("${uten.report-export.directory:}") String directory) {
        this.repository=repository;this.users=users;this.restorer=restorer;this.json=json;
        this.buildIdentity=buildIdentity;this.rateLimiter=rateLimiter;
        this.readScopes=readScopes;this.projectionAccess=projectionAccess;this.master=master;this.workbench=workbench;
        root=directory.isBlank()?null:Path.of(directory).toAbsolutePath().normalize();
    }
    public ReportExportService(ReportExportRepository repository,SecurityContextCurrentUser users,SubmitterPrincipalRestorer restorer,
            ObjectMapper json,ReportExportBuildIdentity buildIdentity,ExportRateLimiter rateLimiter,ReadScopeVersionAuthority readScopes,
            org.springframework.beans.factory.ObjectProvider<com.uten.imp.common.export.ExportProjectionAccessGuard> projectionAccess,String directory) {
        this(repository,users,restorer,json,buildIdentity,rateLimiter,readScopes,projectionAccess,null,null,directory);
    }
    public record View(UUID id,String domain,String report,String format,String status,boolean cancelRequested,int rows,long bytes,OffsetDateTime snapshotAt,
            String error,OffsetDateTime createdAt,OffsetDateTime finishedAt) { }

    public boolean available() {
        principal();
        return root!=null && Files.isDirectory(root,LinkOption.NOFOLLOW_LINKS) && !Files.isSymbolicLink(root);
    }
    @Transactional(readOnly=true)
    public List<View> recent() {
        var user=principal();
        if(user.isVisitor() || user.getImpersonatedBy()!=null) throw new ApiException(ErrorCode.FORBIDDEN);
        var stamp=restorer.currentStamps(user.getId()).orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        return repository.recent(user.getId()).stream()
                .filter(job -> job.authVersion()==stamp.authVersion() && job.authEpoch()==stamp.authorizationEpoch())
                .filter(job -> {
                    try {authorizeRequest(user,decode(job.request()));return true;}
                    catch(ApiException unauthorized) {return false;}
                }).map(this::view).toList();
    }

    @Transactional
    public View submit(ReportExportRequest request) {
        AuthUser user=principal();
        authorizeRequest(user,request);
        if(!Set.of("xlsx","pdf").contains(request.format()))throw new ApiException(ErrorCode.VALIDATION_FAILED,"导出格式无效");
        if(!Set.of("where_used","goods_actual_cost").contains(request.domain()) && !"xlsx".equals(request.format()))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"该报表的持久任务仅支持Excel格式");
        if("where_used".equals(request.domain()) && request.columnProjection()!=null)
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"物料反查证据使用原始多表结构，不接收单表投影");
        if("where_used".equals(request.domain()) && (!"where-used".equals(request.report())
                || request.parameters().keySet().stream().anyMatch(key->!Set.of("materialGoodsId","source","dateFrom","dateTo").contains(key)
                    &&!com.uten.imp.features.production.report.ProductionWhereUsedQueryService.supportsHeaderParameter(key))))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"物料反查导出条件无效");
        if("master".equals(request.domain())) {
            if(master==null)throw new IllegalStateException("Master export adapter is unavailable");
            master.validate(request);
        } else if(request.parameters().values().stream().anyMatch(value->value.length()>2000))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"导出筛选条件过长");
        if(Set.of("workbench_purchase", "workbench_subcontract").contains(request.domain())) {
            if(workbench==null)throw new IllegalStateException("Workbench export adapter is unavailable");
            workbench.validateRequest(request);
        }
        if("audit".equals(request.domain()))AuditReportExportSource.criteria(request);
        if("goods_actual_cost".equals(request.domain()))ActualCostReportExportSource.input(request);
        requireStorage();
        if(request.parameters().keySet().stream().anyMatch(key ->
                key.toLowerCase(Locale.ROOT).matches(".*(password|token|secret|authorization).*")))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"导出筛选不能包含密码或凭据");
        String serialized=serialize(request);
        if(serialized.getBytes(java.nio.charset.StandardCharsets.UTF_8).length>65536)
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"导出筛选条件过大");
        repository.lockQueue();
        var old=repository.find(request.id());
        if(old.isPresent()) {
            var job=authorize(old.get());
            if(!decode(job.request()).equals(request)) throw new ApiException(ErrorCode.CONFLICT,"该导出编号已用于另一组条件，请核对原任务");
            return view(job);
        }
        if(repository.active(user.getId())>=2 || repository.active(null)>=40)
            throw new ApiException(ErrorCode.RATE_LIMITED,"导出任务较多，请等待已有任务完成");
        var stamps=restorer.currentStamps(user.getId()).orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        authorizeRequest(restorer.restore(user.getId(),stamps.authVersion(),stamps.authorizationEpoch()),request);
        rateLimiter.check(user.getId());
        String access=readScopes.scopeFor(authorityDomain(request),user);
        repository.insert(request,user.getId(),stamps.authVersion(),stamps.authorizationEpoch(),serialized,buildIdentity.revision(),access);
        return view(repository.find(request.id()).orElseThrow());
    }
    @Transactional(readOnly=true)
    public View get(UUID id) { return view(authorized(id)); }
    @Transactional
    public View cancel(UUID id) {
        var job=authorized(id);
        repository.cancel(id,job.owner());
        return view(repository.find(id).orElseThrow());
    }
    public ReportExportRepository.Job authorized(UUID id) {
        return authorize(repository.find(id).orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND)));
    }
    public ReportExportRepository.Job authorizedArtifact(UUID id) {
        var job=authorized(id);requireCompatibleReader(job);requireCurrentAccess(job);return job;
    }
    public void requireCurrentAccess(ReportExportRepository.Job job) {
        var request=decode(job.request());
        if(job.accessStamp()==null || !job.accessStamp().equals(readScopes.scopeFor(authorityDomain(request),principal())))
            throw new ApiException(ErrorCode.CONFLICT,"导出数据范围已变化，请按当前权限重新生成任务");
        if(request.columnProjection()!=null)
            projectionAccess.getObject().verify(("master".equals(request.domain())?master.projection(request):request.columnProjection()),ReportExportSource.scope(request));
    }
    private ReportExportRepository.Job authorize(ReportExportRepository.Job job) {
        AuthUser current=principal();
        if(current.getImpersonatedBy()!=null) throw new ApiException(ErrorCode.IMPERSONATION_READ_ONLY);
        if(!current.getId().equals(job.owner())) throw new ApiException(ErrorCode.NOT_FOUND);
        try {
            var fresh=restorer.restore(job.owner(),job.authVersion(),job.authEpoch());
            authorizeRequest(fresh,decode(job.request()));
        } catch(SubmitterPrincipalRestorer.PrincipalChangedException changed) {
            throw new ApiException(ErrorCode.FORBIDDEN,"账号或权限已变化，请重新创建导出任务");
        }
        return job;
    }
    public static void authorizeDomain(AuthUser user,String domain) {
        if(domain==null||!DOMAINS.contains(domain)||"master".equals(domain)) throw new ApiException(ErrorCode.VALIDATION_FAILED,"报表类型无效");
        if(user.isVisitor() || user.isMustChangePassword() || !user.isAccountNonLocked() || user.getImpersonatedBy()!=null
                || ("where_used".equals(domain) && !user.getPermissions().contains("production_where_used:view"))
                || !user.getPermissions().contains(permissionPrefix(domain)+":export"))
            throw new ApiException(ErrorCode.FORBIDDEN);
    }
    public static void authorizeRequest(AuthUser user,ReportExportRequest request) {
        if("goods_actual_cost".equals(request.domain())) {ActualCostReportExportSource.authorize(user);return;}
        if("audit".equals(request.domain())) {AuditReportExportSource.authorize(user);return;}
        if(Set.of("workbench_purchase", "workbench_subcontract").contains(request.domain())) {WorkbenchReportExportPort.authorize(user,request.domain());return;}
        if(!"master".equals(request.domain())) {authorizeDomain(user,request.domain());return;}
        String permission=MasterReportExportPort.permission(request.report());
        if(user.isVisitor()||user.isMustChangePassword()||!user.isAccountNonLocked()||user.getImpersonatedBy()!=null
                ||!user.getPermissions().contains(permission))throw new ApiException(ErrorCode.FORBIDDEN);
    }
    private static String permissionPrefix(String domain) {return "where_used".equals(domain)?"production_where_used":domain+"_report";}
    private static String authorityDomain(ReportExportRequest request) {
        return "goods_actual_cost".equals(request.domain())?"master_goods"
                :"master".equals(request.domain())?MasterReportExportPort.authorityDomain(request.report())
                :"where_used".equals(request.domain())?"production"
                :com.uten.imp.common.report.ProcurementReadRoutes.workbenchDomainScope(request.domain())!=null
                    ?com.uten.imp.common.report.ProcurementReadRoutes.workbenchDomainScope(request.domain()):request.domain();
    }
    private AuthUser principal() {
        return users.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
    }
    public Path requireStorage() {
        if(root==null || !Files.isDirectory(root,LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(root))
            throw new ApiException(ErrorCode.PRIMARY_UNAVAILABLE,"后台导出目录尚未配置，请联系管理员");
        return root;
    }
    public Path artifact(ReportExportRepository.Job job) {
        String format=decode(job.request()).format();
        if(!Set.of("xlsx","pdf").contains(format))throw new IllegalStateException("Invalid stored export format");
        return requireStorage().resolve(job.id()+"-"+job.attempt()+"."+format);
    }
    public void requireCompatibleReader(ReportExportRepository.Job job) {
        String actual=buildIdentity.revision();
        if(actual==null || !ReportExportBuildIdentity.CONTRACT.equals(job.contract()) || !actual.equals(job.buildIdentity()))
            throw new ApiException(ErrorCode.CONFLICT,"导出实现已更新，请重新创建任务；新任务使用新的读取时点");
    }
    public ReportExportRequest decode(String value) {
        try { return json.readValue(value,ReportExportRequest.class); }
        catch(java.io.IOException error) { throw new IllegalStateException("Export request cannot be read",error); }
    }
    private String serialize(ReportExportRequest request) {
        try { return json.writeValueAsString(request); }
        catch(java.io.IOException error) { throw new IllegalStateException(error); }
    }
    private View view(ReportExportRepository.Job job) {
        var request=decode(job.request());
        String state="SUCCEEDED".equals(job.status()) && job.expiresAt().isBefore(OffsetDateTime.now())?"EXPIRED":job.status();
        return new View(job.id(),request.domain(),request.report(),request.format(),state,job.cancelRequested(),job.rows(),job.bytes(),job.snapshotAt(),job.error(),job.createdAt(),job.finishedAt());
    }
}
