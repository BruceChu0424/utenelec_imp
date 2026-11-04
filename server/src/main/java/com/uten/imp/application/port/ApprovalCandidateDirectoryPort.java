package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/** Current employee accounts with a real grant; notice subscriptions and administrator mirrors are independent. */
public interface ApprovalCandidateDirectoryPort {
    List<Candidate> candidates(String permission);
    List<Candidate> candidates(String permission,java.util.Set<String> prerequisites);
    record Candidate(UUID userId,UUID employeeId) {}
}
