package com.uten.imp.features.master.warehouse;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.OrganizationReferencePort;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.features.master.warehouse.dto.WarehouseSaveRequest;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class WarehouseRemarkContractTest {
    @AfterEach void clear(){SecurityContextHolder.clearContext();}
    @Test void omittedRemarkSurvivesUnrelatedEditAndExplicitValueOrNullRoundTripsThroughDetail() throws Exception {
        SecurityContextHolder.getContext().setAuthentication(new TestingAuthenticationToken("staff","unused","warehouse:edit"));
        var repository=mock(WarehouseRepository.class);
        var rules=mock(WarehouseMasterRules.class);
        var organizations=mock(OrganizationReferencePort.class);
        when(organizations.findActiveDepartment(any())).thenReturn(Optional.empty());
        when(rules.selectableDefective(any())).thenReturn(Set.of());
        var service=new WarehouseService(repository,mock(TxSessionVars.class),mock(EntityManager.class),mock(MasterCodeService.class),
                organizations,mock(WarehouseKeeperService.class),rules);
        var warehouse=new Warehouse();warehouse.setName("子仓");warehouse.setStatus("使用");warehouse.setRemark("历史备注");
        var stored=new HashMap<UUID,Warehouse>();stored.put(warehouse.getId(),warehouse);
        when(repository.findById(any(UUID.class))).thenAnswer(call->Optional.ofNullable(stored.get(call.getArgument(0))));
        when(repository.save(any(Warehouse.class))).thenAnswer(call->{Warehouse value=call.getArgument(0);stored.put(value.getId(),value);return value;});
        var json=new ObjectMapper();
        var omitted=json.readValue("{\"name\":\"更名子仓\",\"status\":\"使用\"}",WarehouseSaveRequest.class);
        assertThat(omitted.isRemarkProvided()).isFalse();
        assertThat(service.update(warehouse.getId(),omitted).getRemark()).isEqualTo("历史备注");
        assertThat(service.detail(warehouse.getId()).getRemark()).isEqualTo("历史备注");
        var changed=json.readValue("{\"name\":\"子仓\",\"status\":\"使用\",\"remark\":\"人工更新备注\"}",WarehouseSaveRequest.class);
        assertThat(changed.isRemarkProvided()).isTrue();
        assertThat(service.update(warehouse.getId(),changed).getRemark()).isEqualTo("人工更新备注");
        var cleared=json.readValue("{\"name\":\"子仓\",\"status\":\"使用\",\"remark\":null}",WarehouseSaveRequest.class);
        assertThat(cleared.isRemarkProvided()).isTrue();
        assertThat(service.update(warehouse.getId(),cleared).getRemark()).isNull();
        assertThat(service.detail(warehouse.getId()).getRemark()).isNull();
        var creation=json.readValue("{\"name\":\"新增仓库\",\"status\":\"使用\",\"remark\":\"新建备注\"}",WarehouseSaveRequest.class);
        var created=service.create(creation);
        assertThat(created.getRemark()).isEqualTo("新建备注");
        assertThat(service.detail(created.getId()).getRemark()).isEqualTo("新建备注");
    }
}
