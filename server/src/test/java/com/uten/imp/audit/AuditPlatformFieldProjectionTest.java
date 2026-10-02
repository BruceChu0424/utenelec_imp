package com.uten.imp.audit;

import org.junit.jupiter.api.Test;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;

class AuditPlatformFieldProjectionTest {
    @Test void oldFullFieldSnapshotsCannotBypassBusinessOrPriceAuthorityAndRemainStoredIntact() {
        String original="{\"scope\":\"sales_order_item\",\"record_id\":\"079bd09e-a8e6-4e2e-b909-6d082b8eb433\",\"version\":3,"
                +"\"name\":\"confidential-column-name\",\"cells\":[{\"value\":\"confidential-original-value\"}],"
                +"\"formula\":{\"constant\":\"confidential-formula\"},\"payload\":{\"secret\":\"confidential-payload\"}}";
        for(String table:List.of("platform_record_fields","platform_record_field_versions","platform_column_definitions")) {
            var stored=event(table,original,original);var dto=AuditLogDetail.of(stored,new AuditEventInterpreter());
            assertThat(dto.before()).contains("sales_order_item","079bd09e","version").doesNotContain("confidential","cells","formula","payload");
            assertThat(dto.after()).isEqualTo(dto.before());
            assertThat(dto.summary()+dto.changeSummary()+dto.targetName()).doesNotContain("confidential");
            assertThat(dto.changeSummary()).contains("受控读取","当前业务范围与价格权限").doesNotContain("原单据历史");
            assertThat(stored.getBefore()).isEqualTo(original);assertThat(stored.getAfter()).isEqualTo(original);
        }
    }
    @Test void publicAuditedBusinessChangesKeepTheirExistingPayloadAndExplanation() {
        String before="{\"code\":\"OLD-CODE\"}",after="{\"code\":\"NEW-CODE\"}";
        var dto=AuditLogDetail.of(event("goods",before,after),new AuditEventInterpreter());
        assertThat(dto.before()).isEqualTo(before);assertThat(dto.after()).isEqualTo(after);
        assertThat(dto.changeSummary()).contains("OLD-CODE","NEW-CODE");
    }
    private AuditLog event(String table,String before,String after) {
        var log=new AuditLog();log.setAction("update");log.setTargetType(table);log.setBefore(before);log.setAfter(after);
        log.setResult("success");log.setEventSource("data_change");return log;
    }
}
