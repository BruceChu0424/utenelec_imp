package com.uten.imp.audit;

import com.uten.imp.common.export.*;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.util.*;

/** Reuses the same bounded, authorized session query as the visible table. */
@Service
@RequiredArgsConstructor
public class AuditSessionTableExportService {
    public static final String TABLE_KEY="features.admin.pages.audit_overview_widgets.AuditSessionTable.build.1";
    private final AuditSessionQueryService query;
    private static final List<ExportColumn> COLUMNS=List.of(
        new ExportColumn("actor","操作人","text"),new ExportColumn("login","登录时间 (北京时间)","text"),
        new ExportColumn("status","会话状态","text"),new ExportColumn("device","设备","text"),
        new ExportColumn("operations","人工操作","number"),new ExportColumn("failures","失败操作","number"),
        new ExportColumn("postLogout","退出后操作","number"),new ExportColumn("logout","退出 / 最后活动","text"),
        new ExportColumn("credential","凭证状态","text"));
    @Transactional(readOnly=true)
    @PreAuthorize("hasAuthority('audit_log:view') and hasAuthority('audit_log:export')")
    public ExportPayload export(UUID actor,LocalDate from,LocalDate to,Long snapshot,int maxRows) {
        if(maxRows<1||maxRows>100000)throw new ApiException(ErrorCode.VALIDATION_FAILED,"导出行数上限配置异常");
        int limit=Math.min(10000,maxRows);
        var first=query.sessions(actor,from,to,1,AuditSessionQueryService.MAX_SESSION_PAGE_SIZE,snapshot);
        if(first.total()>limit)throw new ApiException(ErrorCode.VALIDATION_FAILED,"当前会话数超过导出上限，请缩小日期范围");
        List<Map<String,Object>> rows=new ArrayList<>();
        append(rows,first.items());
        for(int page=2;page<=first.totalPages();page++) {
            var next=query.sessions(actor,from,to,page,AuditSessionQueryService.MAX_SESSION_PAGE_SIZE,first.snapshotAuditId());
            if(next.total()!=first.total()||next.snapshotAuditId()!=first.snapshotAuditId())
                throw new ApiException(ErrorCode.CONFLICT,"会话查询范围已变化，请刷新后重试");
            append(rows,next.items());
            if(rows.size()>limit)throw new ApiException(ErrorCode.VALIDATION_FAILED,"会话数超过导出上限");
        }
        return new ExportPayload(COLUMNS,rows,rows.size());
    }
    private void append(List<Map<String,Object>> rows,List<AuditSessionRow> source) {
        for(var item:source) {
            Map<String,Object> row=new LinkedHashMap<>();
            row.put("actor",item.actorDisplay());row.put("login",time(item.loginAt()));
            row.put("status",item.statusLabel());row.put("device",item.deviceLabel());
            row.put("operations",item.operationCount());row.put("failures",item.failureCount());
            row.put("postLogout",item.postLogoutCount());
            row.put("logout",time(item.logoutAt()!=null?item.logoutAt():item.lastActivityAt()!=null?item.lastActivityAt():item.firstActivityAt()));
            row.put("credential",item.refreshCredentialStatusLabel());rows.add(row);
        }
    }
    private static String time(OffsetDateTime value) {
        return value==null?null:value.atZoneSameInstant(BusinessTime.ZONE).format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss"));
    }
}
