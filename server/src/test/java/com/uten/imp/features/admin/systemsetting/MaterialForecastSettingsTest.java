package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.audit.AuditService;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class MaterialForecastSettingsTest {
    final SystemSettingRepository repo=mock(SystemSettingRepository.class);
    final SystemSettingsWriteAuthority authority=mock(SystemSettingsWriteAuthority.class);
    final AuditService audit=mock(AuditService.class);
    final SystemSettingsService service=new SystemSettingsService(repo,audit,mock(TxSessionVars.class),authority);
    final UUID actor=UUID.randomUUID();
    final Set<SystemSettingKey> keys=EnumSet.of(SystemSettingKey.MATERIAL_FORECAST_ENABLED,SystemSettingKey.MATERIAL_FORECAST_INTERVAL_MINUTES,SystemSettingKey.MATERIAL_FORECAST_HISTORY_DAYS,SystemSettingKey.MATERIAL_FORECAST_BACKFILL_BUDGET);
    SystemSetting row(SystemSettingKey key,String value){var row=new SystemSetting();row.setKey(key.key());row.setValue(value);return row;}
    @Test void policyReadsAllFourEffectiveValuesInOneSourceQueryAndPreservesExplicitFalse() {
        when(repo.findAllById(any())).thenReturn(List.of(row(SystemSettingKey.MATERIAL_FORECAST_ENABLED,"false"),row(SystemSettingKey.MATERIAL_FORECAST_INTERVAL_MINUTES,"30")));
        var snapshot=service.readSnapshot(keys);assertThat(snapshot).containsEntry(SystemSettingKey.MATERIAL_FORECAST_ENABLED,"false").containsEntry(SystemSettingKey.MATERIAL_FORECAST_INTERVAL_MINUTES,"30").containsEntry(SystemSettingKey.MATERIAL_FORECAST_HISTORY_DAYS,"1200");
        verify(repo,times(1)).findAllById(any());verify(repo,never()).findById(any());
    }
    @Test void marketSettingsReuseBatchCasAuditAndDeclareDeferredApplication() {
        var enabled=row(SystemSettingKey.MATERIAL_FORECAST_ENABLED,"true");when(repo.findAllForUpdate(anyCollection())).thenReturn(List.of(enabled));when(repo.findAll()).thenReturn(List.of(enabled));
        var result=service.writeBatch(new SystemSettingDto.BatchUpdate(List.of(new SystemSettingDto.Change(enabled.getKey(),"false","true"))),actor,"admin");
        verify(authority).require(actor,true);verify(audit).logCommitted(eq(actor),eq("admin"),eq("update_system_setting"),eq("system_settings"),anyString(),eq("success"));
        assertThat(result.getFirst().category()).isEqualTo("material_market");assertThat(result.getFirst().applyMode()).isEqualTo("NEXT_SCHEDULED_RUN");assertThat(enabled.getValue()).isEqualTo("false");
    }
    @Test void invalidMinutesAndStaleValuesFailBeforeAnyMutation() {
        var interval=row(SystemSettingKey.MATERIAL_FORECAST_INTERVAL_MINUTES,"15");when(repo.findAllForUpdate(anyCollection())).thenReturn(List.of(interval));
        for(var change:List.of(new SystemSettingDto.Change(interval.getKey(),"14","15"),new SystemSettingDto.Change(interval.getKey(),"30","20"))) {
            assertThatThrownBy(()->service.writeBatch(new SystemSettingDto.BatchUpdate(List.of(change)),actor,"admin")).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        }
        assertThat(interval.getValue()).isEqualTo("15");verify(repo,never()).save(any());verifyNoInteractions(audit);
    }
    @Test void delegatedBusinessWritersCannotBypassTheAdministratorConfirmationPath() {
        assertThatThrownBy(()->service.writeDelegated(SystemSettingKey.MATERIAL_FORECAST_ENABLED,"false",actor,"admin","test")).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        verifyNoInteractions(repo,audit);
    }
    @Test void strictPolicyDefaultsOnlyMissingRowsAndPreservesAnExplicitFalse() {
        var policy=new com.uten.imp.features.admin.materialforecast.MaterialForecastPolicyService(service);
        when(repo.findAllById(any())).thenReturn(List.of());
        assertThat(policy.current()).isEqualTo(com.uten.imp.features.admin.materialforecast.MaterialForecastPolicyService.policy(true,15,1200,30));
        when(repo.findAllById(any())).thenReturn(List.of(row(SystemSettingKey.MATERIAL_FORECAST_ENABLED," false "),row(SystemSettingKey.MATERIAL_FORECAST_INTERVAL_MINUTES,"30")));
        assertThat(policy.current()).isEqualTo(com.uten.imp.features.admin.materialforecast.MaterialForecastPolicyService.policy(false,30,1200,30));
        verify(repo,times(2)).findAllById(any());verify(repo,never()).findById(any());
        verifyNoInteractions(audit,authority);
    }
    @Test void strictPolicyRejectsPresentNullMalformedOverflowAndOutOfRangeNumericRows() {
        var policy=new com.uten.imp.features.admin.materialforecast.MaterialForecastPolicyService(service);
        for(var key:List.of(SystemSettingKey.MATERIAL_FORECAST_INTERVAL_MINUTES,SystemSettingKey.MATERIAL_FORECAST_HISTORY_DAYS,SystemSettingKey.MATERIAL_FORECAST_BACKFILL_BUDGET)) {
            for(String corrupt:Arrays.asList(null,"","private-non-numeric-value","2147483648",Long.toString(key.min()-1),Long.toString(key.max()+1))) {
                when(repo.findAllById(any())).thenReturn(List.of(row(key,corrupt)));
                assertThatThrownBy(policy::current).as("invalid persisted %s",key.key()).isInstanceOf(IllegalStateException.class)
                        .hasMessage("Invalid persisted material market policy").hasNoCause();
            }
        }
        verify(repo,never()).save(any());verifyNoInteractions(audit,authority);
    }
    @Test void strictPolicyRejectsPresentCorruptBooleansInsteadOfEnablingTheDefault() {
        var policy=new com.uten.imp.features.admin.materialforecast.MaterialForecastPolicyService(service);
        for(String corrupt:Arrays.asList(null,"","private-invalid-switch","0","yes")) {
            when(repo.findAllById(any())).thenReturn(List.of(row(SystemSettingKey.MATERIAL_FORECAST_ENABLED,corrupt)));
            assertThatThrownBy(policy::current).isInstanceOf(IllegalStateException.class)
                    .hasMessage("Invalid persisted material market policy").hasNoCause();
        }
        verify(repo,never()).save(any());verifyNoInteractions(audit,authority);
    }
    @Test void strictPolicyAcceptsRegisteredNumericBoundaries() {
        var policy=new com.uten.imp.features.admin.materialforecast.MaterialForecastPolicyService(service);
        for(var expected:List.of(com.uten.imp.features.admin.materialforecast.MaterialForecastPolicyService.policy(false,15,3,0),
                com.uten.imp.features.admin.materialforecast.MaterialForecastPolicyService.policy(false,60,3650,1000))) {
            when(repo.findAllById(any())).thenReturn(List.of(row(SystemSettingKey.MATERIAL_FORECAST_ENABLED,"FALSE"),
                    row(SystemSettingKey.MATERIAL_FORECAST_INTERVAL_MINUTES,Integer.toString(expected.intervalMinutes())),
                    row(SystemSettingKey.MATERIAL_FORECAST_HISTORY_DAYS,Integer.toString(expected.historyDays())),
                    row(SystemSettingKey.MATERIAL_FORECAST_BACKFILL_BUDGET,Integer.toString(expected.backfillBudget()))));
            assertThat(policy.current()).isEqualTo(expected);
        }
    }
    @Test void legacyTolerantSnapshotStillUsesDefaultsForCorruptStoredValues() {
        when(repo.findAllById(any())).thenReturn(List.of(row(SystemSettingKey.MATERIAL_FORECAST_ENABLED,"broken-switch"),
                row(SystemSettingKey.MATERIAL_FORECAST_INTERVAL_MINUTES,"broken-integer")));
        assertThat(service.readSnapshot(keys)).containsEntry(SystemSettingKey.MATERIAL_FORECAST_ENABLED,"true")
                .containsEntry(SystemSettingKey.MATERIAL_FORECAST_INTERVAL_MINUTES,"15");
        assertThatThrownBy(service::readMaterialForecastSnapshotStrict).isInstanceOf(IllegalStateException.class)
                .hasMessage("Invalid persisted material market policy").hasNoCause();
        verify(repo,never()).save(any());verifyNoInteractions(audit,authority);
    }
}
