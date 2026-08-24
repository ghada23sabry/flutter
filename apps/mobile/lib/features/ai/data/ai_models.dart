/// API models for the AI count domain (scan sessions, detections,
/// reconciliations), mirroring `app/schemas/ai.py`.
library;

/// Scan lifecycle states surfaced by the UI. The server remains authoritative;
/// these mirror the backend statuses so the client never asserts inventory
/// changed outside an explicit confirm response.
enum AiScanUiState {
  /// Picking zone / shelf / test image.
  idle,

  /// `POST /ai/scans` in flight.
  creating,

  /// `POST /ai/scans/{id}/process` in flight.
  processing,

  /// Scan processed successfully (`completed`) — results being fetched.
  loaded,

  /// Scan processed with unresolved/low-confidence detections
  /// (`needs_review`) — still explicitly confirmable.
  needsReview,

  /// Results loaded and the scan may be explicitly confirmed.
  readyToConfirm,

  /// `POST /ai/scans/{id}/confirm` in flight.
  confirming,

  /// Confirm response received — inventory change is now authoritative.
  confirmed,

  /// A scan/processing/confirm attempt failed.
  failed,
}

/// Scan operations supported by the backend (`ScanOperation`).
///
/// Determines what a confirmed scan does to stock and which movement type is
/// recorded: count replaces (COUNT), receive adds (PURCHASE), sale subtracts
/// (SALE). The server remains authoritative; this mirrors the backend literal.
enum AiScanOperation {
  count,
  receive,
  sale;

  String get wire => name;

  static AiScanOperation fromWire(Object? value) => switch (value) {
    'receive' => receive,
    'sale' => sale,
    _ => count,
  };
}

double _toDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

double? _toNullableDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

DateTime _toDateTime(Object? value) => value is String
    ? (DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0))
    : DateTime.fromMillisecondsSinceEpoch(0);

DateTime? _toNullableDateTime(Object? value) =>
    value is String && value.isNotEmpty
    ? (DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0))
    : null;

/// A scan session (`ScanSessionOut` or `ConfirmScanResponse`).
class ScanSession {
  const ScanSession({
    required this.id,
    required this.storeId,
    required this.operation,
    this.shelfId,
    required this.status,
    this.note,
    required this.imageCount,
    this.startedBy,
    this.completedBy,
    required this.createdAt,
    required this.updatedAt,
    this.completedAt,
    this.productsUpdated,
    this.totalDetections,
    this.unmatchedDetections,
  });

  factory ScanSession.fromJson(Map<String, dynamic> json) => ScanSession(
    id: json['id'] as String,
    storeId: json['store_id'] as String,
    operation: AiScanOperation.fromWire(json['operation']),
    shelfId: json['shelf_id'] as String?,
    status: json['status'] as String? ?? 'processing',
    note: json['note'] as String?,
    imageCount: (json['image_count'] as num?)?.toInt() ?? 0,
    startedBy: json['started_by'] as String?,
    completedBy: json['completed_by'] as String?,
    createdAt: _toDateTime(json['created_at']),
    updatedAt: _toDateTime(json['updated_at']),
    completedAt: _toNullableDateTime(json['completed_at']),
    productsUpdated: json['products_updated'] as int?,
    totalDetections: json['total_detections'] as int?,
    unmatchedDetections: json['unmatched_detections'] as int?,
  );

  final String id;
  final String storeId;
  final AiScanOperation operation;
  final String? shelfId;
  final String status;
  final String? note;
  final int imageCount;
  final String? startedBy;
  final String? completedBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;

  /// Server-reported count of products whose inventory was actually mutated.
  /// Only populated from ConfirmScanResponse (POST /confirm).
  final int? productsUpdated;
  final int? totalDetections;
  final int? unmatchedDetections;

  bool get isProcessing => status == ScanStatus.processing;
  bool get isCompleted => status == ScanStatus.completed;
  bool get isNeedsReview => status == ScanStatus.needsReview;
  bool get isConfirmed => status == ScanStatus.confirmed;
  bool get isFailed => status == ScanStatus.failed;
  bool get isCancelled => status == ScanStatus.cancelled;

  /// The only statuses the backend accepts on explicit confirmation.
  bool get canConfirm => isCompleted || isNeedsReview;
}

/// A single detection (`DetectionOut`). `productId` is nullable: the mock
/// port never resolves identity — resolution is server-side business logic.
class ScanDetection {
  const ScanDetection({
    required this.id,
    required this.sessionId,
    this.productId,
    required this.method,
    this.detectedSku,
    this.detectedBarcode,
    this.confidence,
    required this.quantityDetected,
    required this.status,
    this.meta,
    this.imageKey,
    required this.createdAt,
    this.productName,
    this.productSku,
    this.productBarcode,
  });

  factory ScanDetection.fromJson(Map<String, dynamic> json) => ScanDetection(
    id: json['id'] as String,
    sessionId: json['session_id'] as String,
    productId: json['product_id'] as String?,
    method: json['method'] as String? ?? 'visual',
    detectedSku: json['detected_sku'] as String?,
    detectedBarcode: json['detected_barcode'] as String?,
    confidence: _toNullableDouble(json['confidence']),
    quantityDetected: _toDouble(json['quantity_detected']),
    status: json['status'] as String? ?? 'needs_review',
    meta: json['meta'] is Map<String, dynamic>
        ? json['meta'] as Map<String, dynamic>
        : null,
    imageKey: json['image_key'] as String?,
    createdAt: _toDateTime(json['created_at']),
    productName: json['product_name'] as String?,
    productSku: json['product_sku'] as String?,
    productBarcode: json['product_barcode'] as String?,
  );

  final String id;
  final String sessionId;
  final String? productId;
  final String method;
  final String? detectedSku;
  final String? detectedBarcode;
  final double? confidence;
  final double quantityDetected;
  final String status;
  final Map<String, dynamic>? meta;
  final String? imageKey;
  final DateTime createdAt;
  final String? productName;
  final String? productSku;
  final String? productBarcode;

  bool get isAccepted => status == DetectionStatus.accepted;
  bool get isUnmatched => productId == null;

  /// AI-detected name from vision metadata.
  String? get metaName => meta?['name'] as String?;
  String? get metaBrand => meta?['brand'] as String?;
  String? get metaCategory => meta?['category'] as String?;
  String? get metaDescription => meta?['description'] as String?;
  String? get metaVariant => meta?['variant'] as String?;
  String? get metaModelName => meta?['model_name'] as String?;
  String? get metaSize => meta?['size'] as String?;
  String? get metaWeight => meta?['weight'] as String?;
  String? get metaVolume => meta?['volume'] as String?;
  String? get metaSellingPrice => meta?['selling_price'] as String?;

  /// Best human label: resolved product → detected barcode → detected SKU → AI name → fallback.
  String get referenceLabel {
    if (productName != null && productName!.isNotEmpty) return productName!;
    if (detectedBarcode != null && detectedBarcode!.isNotEmpty) {
      return detectedBarcode!;
    }
    if (detectedSku != null && detectedSku!.isNotEmpty) {
      return detectedSku!;
    }
    if (metaName != null && metaName!.isNotEmpty) return metaName!;
    return 'Unmatched item';
  }
}

/// Variance row between detected and system quantities (`ReconciliationOut`).
class ScanReconciliation {
  const ScanReconciliation({
    required this.id,
    required this.sessionId,
    required this.productId,
    required this.productName,
    required this.sku,
    required this.detectedQuantity,
    required this.systemQuantity,
    required this.variance,
    required this.status,
    this.resolution,
    required this.createdAt,
  });

  factory ScanReconciliation.fromJson(Map<String, dynamic> json) =>
      ScanReconciliation(
        id: json['id'] as String,
        sessionId: json['session_id'] as String,
        productId: json['product_id'] as String,
        productName: json['product_name'] as String,
        sku: json['sku'] as String? ?? '',
        detectedQuantity: _toDouble(json['detected_quantity']),
        systemQuantity: _toDouble(json['system_quantity']),
        variance: _toDouble(json['variance']),
        status: json['status'] as String? ?? 'needs_review',
        resolution: json['resolution'] as String?,
        createdAt: _toDateTime(json['created_at']),
      );

  final String id;
  final String sessionId;
  final String productId;
  final String productName;
  final String sku;
  final double detectedQuantity;
  final double systemQuantity;
  final double variance;
  final String status;
  final String? resolution;
  final DateTime createdAt;

  bool get hasVariance => (variance - 0).abs() > 0.001;

  /// The row was explicitly excluded from confirmation by the reviewer.
  bool get isIgnored => resolution == ReconciliationResolution.ignore;

  /// The reviewer explicitly chose to apply this row's count.
  bool get isResolvedApply => resolution == ReconciliationResolution.apply;
}

/// Scan session status display metadata.
abstract final class ScanStatus {
  static const String processing = 'processing';
  static const String needsReview = 'needs_review';
  static const String confirmed = 'confirmed';
  static const String cancelled = 'cancelled';
  static const String completed = 'completed';
  static const String failed = 'failed';

  static String label(String status) => switch (status) {
    processing => 'Processing',
    needsReview => 'Needs review',
    confirmed => 'Confirmed',
    cancelled => 'Cancelled',
    completed => 'Completed',
    failed => 'Failed',
    _ => status,
  };
}

/// Detection method display metadata.
abstract final class DetectionMethod {
  static const String barcode = 'barcode';
  static const String visual = 'visual';
  static const String ocr = 'ocr';
  static const String manual = 'manual';

  static String label(String method) => switch (method) {
    barcode => 'Barcode',
    visual => 'Visual',
    ocr => 'OCR',
    manual => 'Manual',
    _ => method,
  };
}

/// Detection status display metadata.
abstract final class DetectionStatus {
  static const String accepted = 'accepted';
  static const String needsReview = 'needs_review';

  static String label(String status) => switch (status) {
    accepted => 'Accepted',
    needsReview => 'Needs review',
    _ => status,
  };
}

/// Reconciliation status display metadata.
abstract final class ReconciliationStatus {
  static const String noChange = 'no_change';
  static const String needsReview = 'needs_review';
  static const String applied = 'applied';

  static String label(String status) => switch (status) {
    noChange => 'No change',
    needsReview => 'Needs review',
    applied => 'Applied',
    _ => status,
  };
}

/// Reconciliation review decision display metadata.
abstract final class ReconciliationResolution {
  static const String apply = 'apply';
  static const String ignore = 'ignore';

  static String label(String resolution) => switch (resolution) {
    apply => 'Applied',
    ignore => 'Ignored',
    _ => resolution,
  };
}
