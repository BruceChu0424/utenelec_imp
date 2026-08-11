package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.Client;
import com.uten.imp.features.master.client.ClientRepository;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.supplier.Supplier;
import com.uten.imp.features.master.supplier.SupplierRepository;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.master.unit.UnitRepository;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class GoodsMasterRelationshipResolverTest {

    private final UnitRepository unitRepo = mock(UnitRepository.class);
    private final ColorRepository colorRepo = mock(ColorRepository.class);
    private final MouldRepository mouldRepo = mock(MouldRepository.class);
    private final ClientRepository clientRepo = mock(ClientRepository.class);
    private final SupplierRepository supplierRepo = mock(SupplierRepository.class);
    private final MasterReferenceValidationPort references = mock(MasterReferenceValidationPort.class);
    private final GoodsMasterRelationshipResolver resolver = new GoodsMasterRelationshipResolver(
            unitRepo, colorRepo, mouldRepo, clientRepo, supplierRepo, references);

    @Test
    void uuidIsAuthoritativeAndLegacyLookupIsNotConsulted() {
        UUID id = UUID.randomUUID();
        Unit target = new Unit();
        target.setId(id);
        target.setLegacyId(17);
        when(unitRepo.findById(id)).thenReturn(Optional.of(target));

        assertSame(target, resolver.unit(id, 999));
        verify(unitRepo, never()).findByLegacyId(anyInt());
    }

    @Test
    void absentUuidFallsBackToTheUniqueLegacyId() {
        Supplier target = new Supplier();
        target.setLegacyId(27);
        when(supplierRepo.findByLegacyId(27)).thenReturn(Optional.of(target));

        assertSame(target, resolver.supplier(null, 27));
    }

    @Test
    void legacyClientFallbackStillEnforcesCurrentOwnerScopeAndActiveState() {
        Client target = new Client();
        target.setLegacyId(37);
        when(clientRepo.findByLegacyId(37)).thenReturn(Optional.of(target));

        assertSame(target, resolver.client(null, 37));
        verify(references).requireVisibleActiveClient(target.getId());
    }

    @Test
    void deletedUuidTargetFailsClosedWithoutLegacyFallback() {
        UUID id = UUID.randomUUID();
        Unit deleted = new Unit();
        deleted.setId(id);
        deleted.setLegacyId(47);
        deleted.setDeleted(true);
        when(unitRepo.findById(id)).thenReturn(Optional.of(deleted));

        ApiException error = assertThrows(ApiException.class, () -> resolver.unit(id, 47));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        verify(unitRepo, never()).findByLegacyId(anyInt());
    }
}
