import 'stock_doc.dart';

/// Physical document and its server revision, captured under the same lock.
class StockDocOutboundReview {
  const StockDocOutboundReview({
    required this.document,
    required this.reviewToken,
  });

  final StockDocDetail document;
  final String reviewToken;

  factory StockDocOutboundReview.fromJson(Map<String, dynamic> json) {
    final token = json['reviewToken'];
    final document = json['document'];
    if (token is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(token) ||
        document is! Map<String, dynamic>) {
      throw const FormatException('Invalid stock outbound review response');
    }
    return StockDocOutboundReview(
      document: StockDocDetail.fromJson(document),
      reviewToken: token,
    );
  }
}
