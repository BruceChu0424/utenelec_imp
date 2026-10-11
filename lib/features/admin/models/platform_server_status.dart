class PlatformServerStatus {
  const PlatformServerStatus({
    required this.databaseConnected,
    this.logoStorage = 'DATABASE',
    this.maxLogoBytes = 524288,
    this.maxLogoDimension = 2048,
    this.attachmentStorageBackend = 'disabled',
    this.attachmentUploadsEnabled = false,
  });

  final bool databaseConnected;
  final String logoStorage;
  final int maxLogoBytes;
  final int maxLogoDimension;
  final String attachmentStorageBackend;
  final bool attachmentUploadsEnabled;

  factory PlatformServerStatus.fromJson(Map<String, dynamic> json) {
    if (json['databaseConnected'] is! bool ||
        json['logoStorage'] != 'DATABASE') {
      throw const FormatException('服务器未返回有效的平台存储能力');
    }
    return PlatformServerStatus(
      databaseConnected: json['databaseConnected'] as bool,
      logoStorage: json['logoStorage'] as String,
      maxLogoBytes: (json['maxLogoBytes'] as num?)?.toInt() ?? 524288,
      maxLogoDimension: (json['maxLogoDimension'] as num?)?.toInt() ?? 2048,
      attachmentStorageBackend:
          json['attachmentStorageBackend'] as String? ?? 'disabled',
      attachmentUploadsEnabled: json['attachmentUploadsEnabled'] == true,
    );
  }
}
