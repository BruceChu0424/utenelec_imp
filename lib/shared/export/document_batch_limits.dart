/// Internal proof-request size. The server independently enforces this bound;
/// a complete document export may contain any number of these read batches.
const orderDocumentAuthorizationBatchSize = 100;
