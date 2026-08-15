package com.uten.imp.features.master;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.color.ColorService;
import com.uten.imp.features.master.color.dto.ColorDetail;
import com.uten.imp.features.master.color.dto.ColorSaveRequest;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.features.master.unit.UnitService;
import com.uten.imp.features.master.unit.dto.UnitDetail;
import com.uten.imp.features.master.unit.dto.UnitSaveRequest;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.Arrays;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ColorUnitOnlineLegacyIdentityTest {

    @Test
    void onlineColorUsesUuidAndLeavesLegacyIdentityNull() {
        ColorRepository repository = mock(ColorRepository.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        MasterCodeService codes = mock(MasterCodeService.class);
        when(repository.existsByNameIgnoreCaseAndDeletedFalse("湖蓝"))
                .thenReturn(false);
        when(repository.save(any(Color.class)))
                .thenAnswer(invocation -> invocation.getArgument(0));
        when(codes.nextCode(MasterCodePrefix.COLOR)).thenReturn("YS000001");
        ColorSaveRequest request = new ColorSaveRequest();
        request.setName(" 湖蓝 ");

        ColorDetail detail = new ColorService(
                repository, tx, mock(EntityManager.class), codes).create(request);

        ArgumentCaptor<Color> saved = ArgumentCaptor.forClass(Color.class);
        verify(repository).save(saved.capture());
        verify(tx).bind();
        assertThat(saved.getValue().getId()).isNotNull();
        assertThat(saved.getValue().getLegacyId()).isNull();
        assertThat(saved.getValue().getCode()).isEqualTo("YS000001");
        assertThat(detail.getId()).isEqualTo(saved.getValue().getId());
        assertThat(detail.getLegacyId()).isNull();
    }

    @Test
    void onlineUnitUsesUuidAndLeavesLegacyIdentityNull() {
        UnitRepository repository = mock(UnitRepository.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        MasterCodeService codes = mock(MasterCodeService.class);
        when(repository.existsByNameIgnoreCaseAndDeletedFalse("箱"))
                .thenReturn(false);
        when(repository.save(any(Unit.class)))
                .thenAnswer(invocation -> invocation.getArgument(0));
        when(codes.nextCode(MasterCodePrefix.UNIT)).thenReturn("DW000001");
        UnitSaveRequest request = new UnitSaveRequest();
        request.setName(" 箱 ");

        UnitDetail detail = new UnitService(
                repository, tx, mock(EntityManager.class), codes).create(request);

        ArgumentCaptor<Unit> saved = ArgumentCaptor.forClass(Unit.class);
        verify(repository).save(saved.capture());
        verify(tx).bind();
        assertThat(saved.getValue().getId()).isNotNull();
        assertThat(saved.getValue().getLegacyId()).isNull();
        assertThat(saved.getValue().getCode()).isEqualTo("DW000001");
        assertThat(detail.getId()).isEqualTo(saved.getValue().getId());
        assertThat(detail.getLegacyId()).isNull();
    }

    @Test
    void repositoriesExposeNoSyntheticLegacySequenceAllocator() {
        assertThat(Arrays.stream(ColorRepository.class.getDeclaredMethods())
                .map(java.lang.reflect.Method::getName))
                .doesNotContain("findMaxLegacyId");
        assertThat(Arrays.stream(UnitRepository.class.getDeclaredMethods())
                .map(java.lang.reflect.Method::getName))
                .doesNotContain("findMaxLegacyId");
    }
}
