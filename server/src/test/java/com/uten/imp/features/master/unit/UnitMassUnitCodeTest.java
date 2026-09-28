package com.uten.imp.features.master.unit;

import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.unit.dto.UnitDetail;
import com.uten.imp.features.master.unit.dto.UnitListItem;
import com.uten.imp.features.master.unit.dto.UnitQueryFilter;
import com.uten.imp.features.master.unit.dto.UnitSaveRequest;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 单位「等于哪种重量单位」(V745/ADR-135)：mass_unit_code 与计量维度同一条 upsert 写入，
 * 维度离开「重量」即清空；代码只收 G/KG/T/JIN/LB/OZ 且只能配合重量维度；重量维度不指定代码也允许。
 * 既有单位的改动涉及「重量」而它又是有库存/出入库记录的货品的基本单位时 409(大白话文案)。
 */
class UnitMassUnitCodeTest {

    private FakeDb db;
    private UnitRepository repository;
    private Unit unit;

    @BeforeEach
    void setUp() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(
                "keeper", null, List.of(new SimpleGrantedAuthority("unit:edit"))));
        db = new FakeDb();
        repository = mock(UnitRepository.class);
        unit = new Unit();
        unit.setCode("DW000017");
        unit.setName("kg");
        unit.setStatus("使用");
        when(repository.findById(unit.getId())).thenReturn(Optional.of(unit));
        when(repository.save(any(Unit.class))).thenAnswer(invocation -> invocation.getArgument(0));
    }

    @AfterEach
    void clearSecurity() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void massDimensionWithCodeIsWrittenInTheSameUpsertAndReturned() {
        UnitDetail detail = service().update(unit.getId(), request("MASS", "kg"));

        FakeDb.Write write = db.singleWrite();
        assertThat(write.sql())
                .contains("insert into unit_measurement_profiles")
                .contains("mass_unit_code = excluded.mass_unit_code");
        assertThat(write.params()).containsEntry("dimension", "MASS").containsEntry("massUnitCode", "KG");
        assertThat(detail.getMeasurementDimension()).isEqualTo("MASS");
        assertThat(detail.getMassUnitCode()).isEqualTo("KG");
    }

    @Test
    void massDimensionWithoutCodeIsAllowedAndStoresNullCode() {
        UnitDetail detail = service().update(unit.getId(), request("MASS", null));

        FakeDb.Write write = db.singleWrite();
        assertThat(write.params()).containsEntry("dimension", "MASS").containsEntry("massUnitCode", null);
        assertThat(detail.getMassUnitCode()).isNull();
    }

    @Test
    void leavingMassClearsTheCodeInTheSameStatement() {
        db.profile = new Object[]{"MASS", "KG"};

        UnitDetail detail = service().update(unit.getId(), request("COUNT", null));

        FakeDb.Write write = db.singleWrite();
        assertThat(write.params()).containsEntry("dimension", "COUNT").containsEntry("massUnitCode", null);
        assertThat(detail.getMassUnitCode()).isNull();
    }

    @Test
    void emptyDimensionMeansUnsetAndDeletesTheProfile() {
        db.profile = new Object[]{"MASS", "G"};

        UnitDetail detail = service().update(unit.getId(), request("", ""));

        assertThat(db.singleWrite().sql()).contains("delete from unit_measurement_profiles");
        assertThat(detail.getMeasurementDimension()).isNull();
        assertThat(detail.getMassUnitCode()).isNull();
    }

    @Test
    void codeOutsideTheClosedCatalogueIsRejected() {
        assertThatThrownBy(() -> service().update(unit.getId(), request("MASS", "KGS")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("克/千克/吨/斤/磅/盎司");
        assertThat(db.writes).isEmpty();
    }

    @Test
    void codeWithoutMassDimensionIsRejected() {
        assertThatThrownBy(() -> service().update(unit.getId(), request("COUNT", "KG")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("只有计量维度为「重量」");
        assertThat(db.writes).isEmpty();
    }

    @Test
    void changingMassOfAUnitUsedByStockedGoodsIsAConflictWithPlainMessage() {
        db.profile = new Object[]{"MASS", "KG"};
        db.stocked = true;

        assertThatThrownBy(() -> service().update(unit.getId(), request("MASS", "G")))
                .isInstanceOfSatisfying(ApiException.class, error -> assertThat(error.getCode())
                        .isEqualTo(ErrorCode.CONFLICT))
                .hasMessage("该单位已被有库存或出入库记录的货品使用, 不能修改计量维度或重量单位");
        assertThat(db.writes).isEmpty();
        assertThat(db.statements).anySatisfy(sql -> assertThat(sql)
                .contains("g.unit_id = :unitId")
                .contains("b.qty <> 0")
                .contains("from stock_movements m"));
    }

    @Test
    void enteringMassOnAStockedUnitIsAlsoAConflict() {
        db.profile = new Object[]{"COUNT", null};
        db.stocked = true;

        assertThatThrownBy(() -> service().update(unit.getId(), request("MASS", "KG")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不能修改计量维度或重量单位");
        assertThat(db.writes).isEmpty();
    }

    @Test
    void nonMassReclassificationOfAStockedUnitDoesNotTouchTheWeightLedgerAndIsAllowed() {
        db.profile = new Object[]{"COUNT", null};
        db.stocked = true;

        service().update(unit.getId(), request("LENGTH", null));

        assertThat(db.singleWrite().params()).containsEntry("dimension", "LENGTH");
        assertThat(db.statements).noneSatisfy(sql -> assertThat(sql).contains("select exists"));
    }

    @Test
    void unchangedSettingIsNotRewrittenAndNotGuarded() {
        db.profile = new Object[]{"MASS", "KG"};
        db.stocked = true;

        UnitDetail detail = service().update(unit.getId(), request("MASS", "KG"));

        assertThat(db.writes).isEmpty();
        assertThat(detail.getMassUnitCode()).isEqualTo("KG");
    }

    @Test
    void newUnitIsNeverGuardedAndReturnsItsSetting() {
        when(repository.existsByNameIgnoreCaseAndDeletedFalse("斤")).thenReturn(false);
        UnitSaveRequest request = request("MASS", "JIN");
        request.setName("斤");
        request.setCode("DW000019");

        UnitDetail detail = service().create(request);

        assertThat(db.singleWrite().params()).containsEntry("massUnitCode", "JIN");
        assertThat(db.statements).noneSatisfy(sql -> assertThat(sql).contains("for update"));
        assertThat(detail.getMassUnitCode()).isEqualTo("JIN");
    }

    @Test
    @SuppressWarnings("unchecked")
    void listAndExportCarryTheMassUnit() {
        Unit piece = new Unit();
        piece.setCode("DW000001");
        piece.setName("个");
        piece.setStatus("使用");
        when(repository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(unit, piece), PageRequest.of(0, 100), 2));
        db.listRows = List.of(new Object[]{unit.getId(), "MASS", "KG"}, new Object[]{piece.getId(), "COUNT", null});
        UnitQueryFilter filter = new UnitQueryFilter(null, null, null, null, null, null);

        List<UnitListItem> items = service().list(filter, 1, 20).getItems();
        assertThat(items).extracting(UnitListItem::getMassUnitCode).containsExactly("KG", null);

        ExportPayload payload = service().export(filter, 1000);
        assertThat(payload.columns()).anySatisfy(column -> assertThat(column.label()).isEqualTo("重量单位"));
        assertThat(payload.rows()).extracting(row -> row.get("massUnit")).containsExactly("千克", "");
        assertThat(UnitService.massUnitDisplay("MASS", null)).isEqualTo("未指定");
    }

    private UnitService service() {
        return new UnitService(repository, mock(TxSessionVars.class), db.em, mock(MasterCodeService.class));
    }

    private static UnitSaveRequest request(String dimension, String massUnitCode) {
        UnitSaveRequest request = new UnitSaveRequest();
        request.setName("kg");
        request.setStatus("使用");
        request.setMeasurementDimension(dimension);
        request.setMassUnitCode(massUnitCode);
        return request;
    }

    /** 按 SQL 文本分派的替身库：现有计量设置、是否被有库存货品使用、列表读取行，并记录写语句。 */
    private static final class FakeDb {
        record Write(String sql, Map<String, Object> params) {
        }

        final EntityManager em = mock(EntityManager.class);
        final List<String> statements = new ArrayList<>();
        final List<Write> writes = new ArrayList<>();
        Object[] profile;
        boolean stocked;
        List<Object[]> listRows = List.of();

        FakeDb() {
            when(em.createNativeQuery(anyString())).thenAnswer(invocation -> query(invocation.getArgument(0)));
        }

        Write singleWrite() {
            assertThat(writes).hasSize(1);
            return writes.get(0);
        }

        /** 一行 Object[](不能用 List.of(array)：单个数组实参会被当成可变参数摊开)。 */
        private List<Object> profileRows() {
            List<Object> rows = new ArrayList<>();
            if (profile != null) rows.add(profile);
            return rows;
        }

        private Query query(String sql) {
            statements.add(sql);
            Map<String, Object> params = new LinkedHashMap<>();
            return mock(Query.class, invocation -> switch (invocation.getMethod().getName()) {
                case "setParameter" -> {
                    Object[] args = invocation.getArguments();
                    if (args[0] instanceof String name) {
                        params.put(name, args[1]);
                    }
                    yield invocation.getMock();
                }
                case "getResultList" -> sql.contains("for update") ? profileRows() : new ArrayList<Object>(listRows);
                case "getSingleResult" -> stocked;
                case "executeUpdate" -> {
                    writes.add(new Write(sql, params));
                    yield 1;
                }
                default -> Mockito.RETURNS_DEFAULTS.answer(invocation);
            });
        }
    }
}
