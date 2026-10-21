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
}
