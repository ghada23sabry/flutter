/// API models for the inventory domain (stock, movements, zones, shelves,
/// expiry), mirroring `app/schemas/inventory.py`.
library;

import '../../../core/util/app_format.dart';

double _toDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

DateTime _toDateTime(Object? value) => value is String
    ? (DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0))
    : DateTime.fromMillisecondsSinceEpoch(0);

DateTime? _toNullableDateTime(Object? value) =>
    value is String && value.isNotEmpty
    ? (DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0))
    : null;

/// Date-only value for `expiry_date` / `received_at` (e.g. `2026-12-01`).
DateTime _toDate(Object? value) {
  final s = value?.toString() ?? '';
  final parsed = DateTime.tryParse(s);
  if (parsed == null) return DateTime.fromMillisecondsSinceEpoch(0);
  return DateTime(parsed.year, parsed.month, parsed.day);
}

class StockSummary {
  const StockSummary({
    required this.totalProducts,
    required this.totalValue,
    required this.healthy,
    required this.lowStock,
    required this.outOfStock,
    required this.nearExpiry,
    required this.expired,
  });

  factory StockSummary.fromJson(Map<String, dynamic> json) => StockSummary(
    totalProducts: (json['total_products'] as num?)?.toInt() ?? 0,
    totalValue: _toDouble(json['total_value']),
    healthy: (json['healthy'] as num?)?.toInt() ?? 0,
    lowStock: (json['low_stock'] as num?)?.toInt() ?? 0,
    outOfStock: (json['out_of_stock'] as num?)?.toInt() ?? 0,
    nearExpiry: (json['near_expiry'] as num?)?.toInt() ?? 0,
    expired: (json['expired'] as num?)?.toInt() ?? 0,
  );

  final int totalProducts;
  final double totalValue;
  final int healthy;
  final int lowStock;
  final int outOfStock;
  final int nearExpiry;
  final int expired;
}

/// Row in the stock overview list (`InventoryOut`).
class StockItem {
  const StockItem({
    required this.productId,
    required this.productName,
    required this.sku,
    this.barcode,
    required this.unit,
    this.categoryName,
    required this.costPrice,
    required this.reorderPoint,
    required this.reorderQuantity,
    required this.expiryTrackingEnabled,
    required this.quantity,
    required this.reservedQuantity,
    required this.availableQuantity,
    required this.stockStatus,
    required this.value,
    this.nearestExpiryDate,
    this.nearestExpiryStatus,
    this.updatedAt,
  });

  factory StockItem.fromJson(Map<String, dynamic> json) => StockItem(
    productId: json['product_id'] as String,
    productName: json['product_name'] as String,
    sku: json['sku'] as String? ?? '',
    barcode: json['barcode'] as String?,
    unit: json['unit'] as String? ?? '',
    categoryName: json['category_name'] as String?,
    costPrice: _toDouble(json['cost_price']),
    reorderPoint: _toDouble(json['reorder_point']),
    reorderQuantity: _toDouble(json['reorder_quantity']),
    expiryTrackingEnabled: json['expiry_tracking_enabled'] as bool? ?? false,
    quantity: _toDouble(json['quantity']),
    reservedQuantity: _toDouble(json['reserved_quantity']),
    availableQuantity: _toDouble(json['available_quantity']),
    stockStatus: json['stock_status'] as String? ?? 'healthy',
    value: _toDouble(json['value']),
    nearestExpiryDate: _toNullableDateTime(json['nearest_expiry_date']),
    nearestExpiryStatus: json['nearest_expiry_status'] as String?,
    updatedAt: _toNullableDateTime(json['updated_at']),
  );

  final String productId;
  final String productName;
  final String sku;
  final String? barcode;
  final String unit;
  final String? categoryName;
  final double costPrice;
  final double reorderPoint;
  final double reorderQuantity;
  final bool expiryTrackingEnabled;
  final double quantity;
  final double reservedQuantity;
  final double availableQuantity;
  final String stockStatus;
  final double value;
  final DateTime? nearestExpiryDate;
  final String? nearestExpiryStatus;
  final DateTime? updatedAt;

  bool get isLowStock => stockStatus == 'low_stock';
  bool get isOutOfStock => stockStatus == 'out_of_stock';

  String get quantityLabel => '${AppFormat.qty(quantity)} $unit'.trim();
}

/// Shelf reference embedded in product stock details.
class ShelfRef {
  const ShelfRef({
    required this.shelfId,
    required this.shelfLabel,
    this.shelfCode,
    required this.zoneId,
    required this.zoneName,
    required this.position,
    required this.isPrimary,
  });

  /// Backend embeds `ShelfWithZoneOut` (fields `id`/`label`/`code`/`zone_name`).
  factory ShelfRef.fromJson(Map<String, dynamic> json) => ShelfRef(
    shelfId: json['id'] as String,
    shelfLabel: json['label'] as String,
    shelfCode: json['code'] as String?,
    zoneId: json['zone_id'] as String,
    zoneName: json['zone_name'] as String? ?? '',
    position: (json['position'] as num?)?.toInt() ?? 0,
    isPrimary: json['is_primary'] as bool? ?? false,
  );

  final String shelfId;
  final String shelfLabel;
  final String? shelfCode;
  final String zoneId;
  final String zoneName;
  final int position;
  final bool isPrimary;
}

/// Expiry batch reference embedded in product stock details.
class ExpiryBatchRef {
  const ExpiryBatchRef({
    required this.id,
    this.batchCode,
    required this.quantity,
    required this.expiryDate,
    required this.status,
    required this.daysRemaining,
  });

  factory ExpiryBatchRef.fromJson(Map<String, dynamic> json) => ExpiryBatchRef(
    id: json['id'] as String,
    batchCode: json['batch_code'] as String?,
    quantity: _toDouble(json['quantity']),
    expiryDate: _toDate(json['expiry_date']),
    status: json['status'] as String? ?? 'normal',
    daysRemaining: (json['days_remaining'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String? batchCode;
  final double quantity;
  final DateTime expiryDate;
  final String status;
  final int daysRemaining;
}

/// Movement reference embedded in product stock details.
class MovementRef {
  const MovementRef({
    required this.id,
    required this.movementType,
    required this.quantityDelta,
    this.resultingQuantity,
    this.referenceType,
    this.referenceId,
    this.notes,
    this.createdBy,
    this.createdByName,
    required this.createdAt,
  });

  factory MovementRef.fromJson(Map<String, dynamic> json) => MovementRef(
    id: json['id'] as String,
    movementType: json['movement_type'] as String? ?? 'ADJUSTMENT',
    quantityDelta: _toDouble(json['quantity_delta']),
    resultingQuantity: json['resulting_quantity'] == null
        ? null
        : _toDouble(json['resulting_quantity']),
    referenceType: json['reference_type'] as String?,
    referenceId: json['reference_id'] as String?,
    notes: json['notes'] as String?,
    createdBy: json['created_by'] as String?,
    createdByName: json['created_by_name'] as String?,
    createdAt: _toDateTime(json['created_at']),
  );

  final String id;
  final String movementType;
  final double quantityDelta;
  final double? resultingQuantity;
  final String? referenceType;
  final String? referenceId;
  final String? notes;
  final String? createdBy;
  final String? createdByName;
  final DateTime createdAt;
}

/// Full stock detail for a single product (`ProductStockOut`).
class ProductStock {
  const ProductStock({
    required this.productId,
    required this.productName,
    required this.sku,
    this.barcode,
    required this.unit,
    this.categoryId,
    this.categoryName,
    required this.costPrice,
    required this.sellingPrice,
    required this.reorderPoint,
    required this.reorderQuantity,
    required this.expiryTrackingEnabled,
    required this.quantity,
    required this.reservedQuantity,
    required this.availableQuantity,
    required this.stockStatus,
    required this.value,
    required this.hasOpening,
    required this.shelves,
    required this.expiryBatches,
    required this.recentMovements,
  });

  factory ProductStock.fromJson(Map<String, dynamic> json) => ProductStock(
    productId: json['product_id'] as String,
    productName: json['product_name'] as String,
    sku: json['sku'] as String? ?? '',
    barcode: json['barcode'] as String?,
    unit: json['unit'] as String? ?? '',
    categoryId: json['category_id'] as String?,
    categoryName: json['category_name'] as String?,
    costPrice: _toDouble(json['cost_price']),
    sellingPrice: _toDouble(json['selling_price']),
    reorderPoint: _toDouble(json['reorder_point']),
    reorderQuantity: _toDouble(json['reorder_quantity']),
    expiryTrackingEnabled: json['expiry_tracking_enabled'] as bool? ?? false,
    quantity: _toDouble(json['quantity']),
    reservedQuantity: _toDouble(json['reserved_quantity']),
    availableQuantity: _toDouble(json['available_quantity']),
    stockStatus: json['stock_status'] as String? ?? 'healthy',
    value: _toDouble(json['value']),
    hasOpening: json['has_opening'] as bool? ?? false,
    shelves: [
      for (final item in (json['shelves'] as List? ?? []))
        ShelfRef.fromJson(item as Map<String, dynamic>),
    ],
    expiryBatches: [
      for (final item in (json['expiry_batches'] as List? ?? []))
        ExpiryBatchRef.fromJson(item as Map<String, dynamic>),
    ],
    recentMovements: [
      for (final item in (json['recent_movements'] as List? ?? []))
        MovementRef.fromJson(item as Map<String, dynamic>),
    ],
  );

  final String productId;
  final String productName;
  final String sku;
  final String? barcode;
  final String unit;
  final String? categoryId;
  final String? categoryName;
  final double costPrice;
  final double sellingPrice;
  final double reorderPoint;
  final double reorderQuantity;
  final bool expiryTrackingEnabled;
  final double quantity;
  final double reservedQuantity;
  final double availableQuantity;
  final String stockStatus;
  final double value;
  final bool hasOpening;
  final List<ShelfRef> shelves;
  final List<ExpiryBatchRef> expiryBatches;
  final List<MovementRef> recentMovements;

  String get quantityLabel => '${AppFormat.qty(quantity)} $unit'.trim();
}

/// Stock movement history row (`StockMovementOut`).
class StockMovement {
  const StockMovement({
    required this.id,
    required this.productId,
    required this.productName,
    required this.sku,
    required this.quantityDelta,
    this.resultingQuantity,
    required this.movementType,
    this.referenceType,
    this.referenceId,
    this.notes,
    this.createdBy,
    this.createdByName,
    required this.createdAt,
  });

  factory StockMovement.fromJson(Map<String, dynamic> json) => StockMovement(
    id: json['id'] as String,
    productId: json['product_id'] as String,
    productName: json['product_name'] as String,
    sku: json['sku'] as String? ?? '',
    quantityDelta: _toDouble(json['quantity_delta']),
    resultingQuantity: json['resulting_quantity'] == null
        ? null
        : _toDouble(json['resulting_quantity']),
    movementType: json['movement_type'] as String? ?? 'ADJUSTMENT',
    referenceType: json['reference_type'] as String?,
    referenceId: json['reference_id'] as String?,
    notes: json['notes'] as String?,
    createdBy: json['created_by'] as String?,
    createdByName: json['created_by_name'] as String?,
    createdAt: _toDateTime(json['created_at']),
  );

  final String id;
  final String productId;
  final String productName;
  final String sku;
  final double quantityDelta;
  final double? resultingQuantity;
  final String movementType;
  final String? referenceType;
  final String? referenceId;
  final String? notes;
  final String? createdBy;
  final String? createdByName;
  final DateTime createdAt;
}

/// Layout zone (`ZoneOut`).
class Zone {
  const Zone({
    required this.id,
    required this.storeId,
    required this.name,
    this.code,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Zone.fromJson(Map<String, dynamic> json) => Zone(
    id: json['id'] as String,
    storeId: json['store_id'] as String,
    name: json['name'] as String,
    code: json['code'] as String?,
    status: json['status'] as String? ?? 'active',
    createdAt: _toDateTime(json['created_at']),
    updatedAt: _toDateTime(json['updated_at']),
  );

  final String id;
  final String storeId;
  final String name;
  final String? code;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isActive => status == 'active';
}

/// Layout shelf (`ShelfOut`).
class Shelf {
  const Shelf({
    required this.id,
    required this.storeId,
    required this.zoneId,
    this.zoneName,
    required this.label,
    this.code,
    required this.position,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Shelf.fromJson(Map<String, dynamic> json) => Shelf(
    id: json['id'] as String,
    storeId: json['store_id'] as String,
    zoneId: json['zone_id'] as String,
    zoneName: json['zone_name'] as String?,
    label: json['label'] as String,
    code: json['code'] as String?,
    position: (json['position'] as num?)?.toInt() ?? 0,
    status: json['status'] as String? ?? 'active',
    createdAt: _toDateTime(json['created_at']),
    updatedAt: _toDateTime(json['updated_at']),
  );

  final String id;
  final String storeId;
  final String zoneId;
  final String? zoneName;
  final String label;
  final String? code;
  final int position;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isActive => status == 'active';
}

/// Shelf↔product mapping (`ShelfProductMapOut`).
class ShelfProductMap {
  const ShelfProductMap({
    required this.id,
    required this.shelfId,
    required this.productId,
    required this.position,
    required this.isPrimary,
    this.productName,
    this.sku,
    this.barcode,
  });

  factory ShelfProductMap.fromJson(Map<String, dynamic> json) =>
      ShelfProductMap(
        id: json['id'] as String,
        shelfId: json['shelf_id'] as String,
        productId: json['product_id'] as String,
        position: (json['position'] as num?)?.toInt() ?? 0,
        isPrimary: json['is_primary'] as bool? ?? false,
        productName: json['product_name'] as String?,
        sku: json['sku'] as String?,
        barcode: json['barcode'] as String?,
      );

  final String id;
  final String shelfId;
  final String productId;
  final int position;
  final bool isPrimary;
  final String? productName;
  final String? sku;
  final String? barcode;
}

/// Expiry batch (`ExpiryBatchOut`).
class ExpiryBatch {
  const ExpiryBatch({
    required this.id,
    required this.productId,
    required this.productName,
    required this.sku,
    this.barcode,
    this.batchCode,
    required this.quantity,
    required this.expiryDate,
    required this.receivedAt,
    required this.status,
    required this.daysRemaining,
    required this.value,
  });

  factory ExpiryBatch.fromJson(Map<String, dynamic> json) => ExpiryBatch(
    id: json['id'] as String,
    productId: json['product_id'] as String,
    productName: json['product_name'] as String,
    sku: json['sku'] as String? ?? '',
    barcode: json['barcode'] as String?,
    batchCode: json['batch_code'] as String?,
    quantity: _toDouble(json['quantity']),
    expiryDate: _toDate(json['expiry_date']),
    receivedAt: _toDate(json['received_at']),
    status: json['status'] as String? ?? 'normal',
    daysRemaining: (json['days_remaining'] as num?)?.toInt() ?? 0,
    value: _toDouble(json['value']),
  );

  final String id;
  final String productId;
  final String productName;
  final String sku;
  final String? barcode;
  final String? batchCode;
  final double quantity;
  final DateTime expiryDate;
  final DateTime receivedAt;
  final String status;
  final int daysRemaining;
  final double value;

  bool get isExpired => status == 'expired';
  bool get isNearExpiry => status == 'near_expiry';

  String get expiryLabel =>
      '${expiryDate.year}-${expiryDate.month.toString().padLeft(2, '0')}-${expiryDate.day.toString().padLeft(2, '0')}';
}

/// Movement type display metadata.
abstract final class MovementType {
  static const String opening = 'OPENING';
  static const String adjustment = 'ADJUSTMENT';
  static const String count = 'COUNT';
  static const String sale = 'SALE';
  static const String purchase = 'PURCHASE';
  static const String transfer = 'TRANSFER';
  static const String writeOff = 'WRITE_OFF';
  static const String manual = 'MANUAL';

  static String label(String type) => switch (type) {
    opening => 'Opening',
    adjustment => 'Adjustment',
    count => 'Count',
    sale => 'Sale',
    purchase => 'Purchase',
    transfer => 'Transfer',
    writeOff => 'Write-off',
    manual => 'Manual',
    _ => type,
  };
}

/// Stock status display metadata.
abstract final class StockStatus {
  static const String healthy = 'healthy';
  static const String lowStock = 'low_stock';
  static const String outOfStock = 'out_of_stock';

  static String label(String status) => switch (status) {
    healthy => 'Healthy',
    lowStock => 'Low Stock',
    outOfStock => 'Out of Stock',
    _ => status,
  };

  static String badgeVariant(String status) => switch (status) {
    lowStock => 'warning',
    outOfStock => 'danger',
    _ => 'success',
  };
}
