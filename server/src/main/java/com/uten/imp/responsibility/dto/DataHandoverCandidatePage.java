package com.uten.imp.responsibility.dto;

import java.util.List;

public record DataHandoverCandidatePage(
        List<DataHandoverCandidate> items,
        int page,
        int size,
        long total
) {
}
