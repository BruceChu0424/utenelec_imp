class HrCelebrationPublication {
  const HrCelebrationPublication({
    required this.id,
    required this.noticeId,
    required this.employeeName,
    required this.type,
    required this.eventLabel,
    required this.publishedAt,
    required this.publisher,
  });
  final String id;
  final String noticeId;
  final String employeeName;
  final String type;
  final String eventLabel;
  final String publishedAt;
  final String publisher;

  factory HrCelebrationPublication.fromJson(Map<String, dynamic> json) =>
      HrCelebrationPublication(
        id: json['id'] as String,
        noticeId: json['noticeId'] as String,
        employeeName: json['employeeName'] as String,
        type: json['type'] as String,
        eventLabel: json['eventLabel'] as String,
        publishedAt: json['publishedAt'] as String,
        publisher: json['publisher'] as String,
      );
}
