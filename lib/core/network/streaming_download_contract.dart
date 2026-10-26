/// Marks the exact authenticated file read which requires a real streaming body.
const streamingDownloadRequestKey = 'uten.export.streaming';
const maxExportDownloadBytes = 384 * 1024 * 1024;
const maxDownloadErrorBytes = 64 * 1024;
