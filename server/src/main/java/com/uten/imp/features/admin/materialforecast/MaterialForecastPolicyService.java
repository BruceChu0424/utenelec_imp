package com.uten.imp.features.admin.materialforecast;

import com.uten.imp.application.port.MaterialForecastRuntimePort.Policy;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;

@Service
@RequiredArgsConstructor
public class MaterialForecastPolicyService {
    private final SystemSettingsService settings;
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Policy current() {
        var values=settings.readMaterialForecastSnapshotStrict();
        String enabled=values.get(SystemSettingKey.MATERIAL_FORECAST_ENABLED);
        if(!"true".equalsIgnoreCase(enabled)&&!"false".equalsIgnoreCase(enabled)) {
            throw new IllegalStateException("Invalid persisted material market policy");
        }
        try {
            return policy(Boolean.parseBoolean(enabled),
                    Integer.parseInt(values.get(SystemSettingKey.MATERIAL_FORECAST_INTERVAL_MINUTES)),
                    Integer.parseInt(values.get(SystemSettingKey.MATERIAL_FORECAST_HISTORY_DAYS)),
                    Integer.parseInt(values.get(SystemSettingKey.MATERIAL_FORECAST_BACKFILL_BUDGET)));
        }catch(NumberFormatException invalid) {
            throw new IllegalStateException("Invalid persisted material market policy");
        }catch(IllegalArgumentException invalid) {
            throw new IllegalStateException("Invalid persisted material market policy");
        }
    }
    public static Policy policy(boolean enabled,int minutes,int days,int budget) {
        if(minutes<15||minutes>60||days<3||days>3650||budget<0||budget>1000)throw new IllegalArgumentException("Invalid market policy");
        String canonical="MATERIAL_FORECAST_POLICY_V1\nenabled="+enabled+"\nintervalMinutes="+minutes+"\nhistoryDays="+days+"\nbackfillBudget="+budget+"\n";
        try {
            String revision=HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(canonical.getBytes(StandardCharsets.UTF_8)));
            return new Policy(enabled,minutes,days,budget,revision);
        }catch(java.security.NoSuchAlgorithmException impossible){throw new IllegalStateException(impossible);}
    }
}
