package com.uten.imp.features.admin.materialforecast;

import com.uten.imp.application.port.MaterialForecastRuntimePort;
import com.uten.imp.application.port.MaterialForecastMarketReadPort;
import com.uten.imp.features.admin.systemsetting.SystemSettingsWriteAuthority;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.time.Instant;
import java.util.List;

@Service
@RequiredArgsConstructor
public class MaterialForecastStatusService {
    private final MaterialForecastRuntimePort runtime;
    private final MaterialForecastMarketReadPort market;
    private final SystemSettingsWriteAuthority authority;
    private final SecurityContextCurrentUser current;
    public record Status(String dataAsOf,String expiresAt,int refreshAfterSeconds,MaterialForecastRuntimePort.Policy configuration,
            MaterialForecastRuntimePort.State runtime,List<MaterialForecastMarketReadPort.Feed> feeds) {}
    @Transactional(readOnly=true)
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin and !principal.visitor and !principal.mustChangePassword and principal.impersonatedBy == null")
    public Status read() {
        var actor=current.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED));
        authority.require(actor.getId(),false);
        Instant now=Instant.now();
        var desired=runtime.configuration();
        var state=runtime.runtime(desired);
        Instant expires=now.plusSeconds(30),confirmedUntil=runtime.confirmationExpiresAt(desired);
        if(state.configurationApplied()&&confirmedUntil!=null&&confirmedUntil.isBefore(expires)) { expires=confirmedUntil; }
        return new Status(now.toString(),expires.toString(),15,desired,state,market.feeds());
    }
}
