package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.ProcurementInspectionPort;
import com.uten.imp.application.port.SubcontractPreStockReleasePort;
import com.uten.imp.common.concurrency.SubcontractHeldPreStock;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.Collection;
import java.util.Comparator;
import java.util.List;
import java.util.UUID;

/**
 * ADR-098 × ADR-090(2026-10-05)：委外回厂「先入库后质检」的合格品在回厂短交待判定期间不转为可用库存；
 * 委外判定(分批到货 / 接受损耗)或后续到货让收货单不再被扣住时，在同一事务里逐张补做自动转正。
 *
 * <p>调用方：委外短交判定({@code SubcontractShortDeliveryService.decide}，经 {@link SubcontractPreStockReleasePort})、
 * 仓库到货登记({@link WarehouseArrivalRegistrationService})。两者都已在本事务首次预锁时并入这些收货单的
 * 品质与入库足迹；仍被扣住的收货单(同一张单另一行还待判定)原样跳过。
 */
@Service
@RequiredArgsConstructor
public class SubcontractHeldPreStockReleaseService implements SubcontractPreStockReleasePort {

    private final EntityManager em;
    private final ProcurementInspectionService inspections;

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public int releaseHeldPreStock(Collection<UUID> orderItemIds) {
        List<UUID> receipts = SubcontractHeldPreStock.ofOrderItems(em, orderItemIds).stream()
                .map(SubcontractHeldPreStock.Release::receiptId)
                .distinct()
                .sorted(Comparator.comparing(UUID::toString))
                .toList();
        int released = 0;
        for (UUID receiptId : receipts) {
            released += inspections.releaseHeldPreStock(ProcurementInspectionPort.SUBCONTRACT, receiptId);
        }
        return released;
    }
}
