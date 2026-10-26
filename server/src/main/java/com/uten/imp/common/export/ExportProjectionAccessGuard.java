package com.uten.imp.common.export;
import com.uten.imp.common.platformcolumns.PlatformColumnService;
import com.uten.imp.common.web.*;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.*;
import java.util.*;

/** Rechecks only selected definitions; never reruns a report to authorize its file. */
@Component
public class ExportProjectionAccessGuard {
    private final PlatformColumnService platform;
    public ExportProjectionAccessGuard(PlatformColumnService platform) {this.platform=platform;}
    @Transactional(readOnly=true,propagation=Propagation.REQUIRES_NEW,isolation=Isolation.REPEATABLE_READ,timeout=15)
    public void verify(TableColumnProjection projection,String scope) {
        if(projection==null || projection.columns()==null)return;
        var ids=projection.columns().stream().filter(c -> c.key()!=null && c.key().startsWith("platform:"))
                .map(c -> UUID.fromString(c.key().substring(9))).distinct().toList();
        if(ids.isEmpty())return;
        if(!scope.equals(projection.scope()))throw new ApiException(ErrorCode.CONFLICT,"导出列范围已变化，请重新生成");
        var available=platform.definitionsByIds(scope,ids).stream().map(d -> d.id()).collect(java.util.stream.Collectors.toSet());
        if(!available.containsAll(ids))throw new ApiException(ErrorCode.CONFLICT,"导出列已不可读取，请重新生成");
    }
}
