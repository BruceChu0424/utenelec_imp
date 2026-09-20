class ExpenseSettings {
  const ExpenseSettings({
    this.companyName = '',
    this.companyTaxNo = '',
    this.submissionGuide = '',
    this.requireInvoice = false,
    this.version = 0,
  });

  final String companyName;
  final String companyTaxNo;
  final String submissionGuide;
  final bool requireInvoice;
  final int version;

  factory ExpenseSettings.fromJson(Map<String, dynamic> json) =>
      ExpenseSettings(
        companyName: json['companyName'] as String? ?? '',
        companyTaxNo: json['companyTaxNo'] as String? ?? '',
        submissionGuide: json['submissionGuide'] as String? ?? '',
        requireInvoice: json['requireInvoice'] == true,
        version: (json['version'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
    'companyName': companyName.trim(),
    'companyTaxNo': companyTaxNo.trim().toUpperCase(),
    'submissionGuide': submissionGuide.trim(),
    'requireInvoice': requireInvoice,
    'version': version,
  };
}
