package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryCostSourceEvidencePort;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import static com.uten.imp.features.stock.valuation.ValueMath.conflict;

/** A single authority entry point without coupling physical custody to a commercial service. */
@Service
public class InventoryCostSourceEvidenceService implements InventoryCostSourceEvidencePort {
    private final List<InventoryApprovedCostEvidenceReader> readers;

    public InventoryCostSourceEvidenceService(List<InventoryApprovedCostEvidenceReader> readers) {
        this.readers = List.copyOf(readers);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public Optional<Evidence> approved(UUID evidenceId, long version) {
        Evidence found = null;
        for (var reader : readers) {
            var evidence = reader.approved(evidenceId, version);
            if (evidence.isEmpty()) continue;
            if (found != null) throw conflict("同一成本来源UUID匹配多个业务，请先核对来源");
            found = evidence.get();
        }
        return Optional.ofNullable(found);
    }
}
