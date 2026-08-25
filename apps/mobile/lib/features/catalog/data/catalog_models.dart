/// API models for the catalog domain (products + suppliers + categories),
/// mirroring `app/schemas/catalog.py`.
library;

/// Parse a Decimal that the backend serializes as a number or string.
double _toDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

DateTime _toDateTime(Object? value) => value is String
    ? (DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0))
    : DateTime.fromMillisecondsSinceEpoch(0);

class Product {
  const Product({
    required this.id,
    required this.storeId,
    this.categoryId,
    this.categoryName,
    required this.sku,
    this.barcode,
    required this.name,
    this.brand,
    this.variant,
    this.modelName,
    this.description,
    required this.unit,
    this.size,
    this.weight,
    this.volume,
    required this.costPrice,
    required this.sellingPrice,
    required this.reorderPoint,
    required this.reorderQuantity,
    required this.expiryTrackingEnabled,
    this.imageUrl,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Product.fromJson(Map<String, dynamic> json) => Product(
    id: json['id'] as String,
    storeId: json['store_id'] as String,
    categoryId: json['category_id'] as String?,
    categoryName: json['category_name'] as String?,
    sku: json['sku'] as String? ?? '',
    barcode: json['barcode'] as String?,
    name: json['name'] as String,
    brand: json['brand'] as String?,
    variant: json['variant'] as String?,
    modelName: json['model_name'] as String?,
    description: json['description'] as String?,
    unit: json['unit'] as String? ?? '',
    size: json['size'] as String?,
    weight: json['weight'] as String?,
    volume: json['volume'] as String?,
    costPrice: _toDouble(json['cost_price']),
    sellingPrice: _toDouble(json['selling_price']),
    reorderPoint: _toDouble(json['reorder_point']),
    reorderQuantity: _toDouble(json['reorder_quantity']),
    expiryTrackingEnabled: json['expiry_tracking_enabled'] as bool? ?? false,
    imageUrl: json['image_url'] as String?,
    status: json['status'] as String? ?? 'active',
    createdAt: _toDateTime(json['created_at']),
    updatedAt: _toDateTime(json['updated_at']),
  );

  final String id;
  final String storeId;
  final String? categoryId;
  final String? categoryName;
  final String sku;
  final String? barcode;
  final String name;
  final String? brand;
  final String? variant;
  final String? modelName;
  final String? description;
  final String unit;
  final String? size;
  final String? weight;
  final String? volume;
  final double costPrice;
  final double sellingPrice;
  final double reorderPoint;
  final double reorderQuantity;
  final bool expiryTrackingEnabled;
  final String? imageUrl;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isActive => status == 'active';

  double get profitMargin =>
      sellingPrice > 0 ? ((sellingPrice - costPrice) / sellingPrice) * 100 : 0;

  Map<String, dynamic> toJson() => {
    'id': id,
    'store_id': storeId,
    'category_id': categoryId,
    'category_name': categoryName,
    'sku': sku,
    'barcode': barcode,
    'name': name,
    'brand': brand,
    'variant': variant,
    'model_name': modelName,
    'description': description,
    'unit': unit,
    'size': size,
    'weight': weight,
    'volume': volume,
    'cost_price': costPrice,
    'selling_price': sellingPrice,
    'reorder_point': reorderPoint,
    'reorder_quantity': reorderQuantity,
    'expiry_tracking_enabled': expiryTrackingEnabled,
    'image_url': imageUrl,
    'status': status,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };
}

/// Create payload (`ProductIn`).
class ProductInput {
  const ProductInput({
    this.categoryId,
    required this.name,
    this.brand,
    this.variant,
    this.modelName,
    this.sku,
    this.barcode,
    this.description,
    required this.unit,
    this.size,
    this.weight,
    this.volume,
    this.costPrice,
    this.sellingPrice,
    this.reorderPoint,
    this.reorderQuantity,
    this.expiryTrackingEnabled,
    this.imageUrl,
  });

  final String? categoryId;
  final String name;
  final String? brand;
  final String? variant;
  final String? modelName;
  final String? sku;
  final String? barcode;
  final String? description;
  final String unit;
  final String? size;
  final String? weight;
  final String? volume;
  final double? costPrice;
  final double? sellingPrice;
  final double? reorderPoint;
  final double? reorderQuantity;
  final bool? expiryTrackingEnabled;
  final String? imageUrl;

  Map<String, dynamic> toJson() => {
    if (categoryId != null) 'category_id': categoryId,
    'name': name,
    if (brand != null) 'brand': brand,
    if (variant != null) 'variant': variant,
    if (modelName != null) 'model_name': modelName,
    if (sku != null) 'sku': sku,
    if (barcode != null) 'barcode': barcode,
    if (description != null) 'description': description,
    'unit': unit,
    if (size != null) 'size': size,
    if (weight != null) 'weight': weight,
    if (volume != null) 'volume': volume,
    if (costPrice != null) 'cost_price': costPrice,
    if (sellingPrice != null) 'selling_price': sellingPrice,
    if (reorderPoint != null) 'reorder_point': reorderPoint,
    if (reorderQuantity != null) 'reorder_quantity': reorderQuantity,
    if (expiryTrackingEnabled != null)
      'expiry_tracking_enabled': expiryTrackingEnabled,
    if (imageUrl != null) 'image_url': imageUrl,
  };
}

/// Partial update payload (`ProductUpdate`). Null means "no change".
class ProductUpdate {
  const ProductUpdate({
    this.categoryId,
    this.clearCategory = false,
    this.name,
    this.brand,
    this.variant,
    this.modelName,
    this.sku,
    this.barcode,
    this.clearBarcode = false,
    this.description,
    this.unit,
    this.size,
    this.weight,
    this.volume,
    this.costPrice,
    this.sellingPrice,
    this.reorderPoint,
    this.reorderQuantity,
    this.expiryTrackingEnabled,
    this.imageUrl,
    this.status,
  });

  final String? categoryId;

  /// When true, send `category_id: null` explicitly to clear an assigned
  /// category during an edit (distinct from "field not supplied").
  final bool clearCategory;
  final String? name;
  final String? brand;
  final String? variant;
  final String? modelName;
  final String? sku;
  final String? barcode;

  /// When true, send `barcode: null` explicitly to clear an assigned barcode
  /// during an edit (distinct from "field not supplied").
  final bool clearBarcode;
  final String? description;
  final String? unit;
  final String? size;
  final String? weight;
  final String? volume;
  final double? costPrice;
  final double? sellingPrice;
  final double? reorderPoint;
  final double? reorderQuantity;
  final bool? expiryTrackingEnabled;
  final String? imageUrl;
  final String? status;

  Map<String, dynamic> toJson() => {
    if (categoryId != null)
      'category_id': categoryId
    else if (clearCategory)
      'category_id': null,
    if (name != null) 'name': name,
    if (brand != null) 'brand': brand,
    if (variant != null) 'variant': variant,
    if (modelName != null) 'model_name': modelName,
    if (sku != null) 'sku': sku,
    if (barcode != null)
      'barcode': barcode
    else if (clearBarcode)
      'barcode': null,
    if (description != null) 'description': description,
    if (unit != null) 'unit': unit,
    if (size != null) 'size': size,
    if (weight != null) 'weight': weight,
    if (volume != null) 'volume': volume,
    if (costPrice != null) 'cost_price': costPrice,
    if (sellingPrice != null) 'selling_price': sellingPrice,
    if (reorderPoint != null) 'reorder_point': reorderPoint,
    if (reorderQuantity != null) 'reorder_quantity': reorderQuantity,
    if (expiryTrackingEnabled != null)
      'expiry_tracking_enabled': expiryTrackingEnabled,
    if (imageUrl != null) 'image_url': imageUrl,
    if (status != null) 'status': status,
  };
}

class Supplier {
  const Supplier({
    required this.id,
    required this.name,
    this.contactName,
    this.phone,
    this.email,
    this.address,
    this.notes,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Supplier.fromJson(Map<String, dynamic> json) => Supplier(
    id: json['id'] as String,
    name: json['name'] as String,
    contactName: json['contact_name'] as String?,
    phone: json['phone'] as String?,
    email: json['email'] as String?,
    address: json['address'] as String?,
    notes: json['notes'] as String?,
    status: json['status'] as String? ?? 'active',
    createdAt: _toDateTime(json['created_at']),
    updatedAt: _toDateTime(json['updated_at']),
  );

  final String id;
  final String name;
  final String? contactName;
  final String? phone;
  final String? email;
  final String? address;
  final String? notes;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isActive => status == 'active';

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'contact_name': contactName,
    'phone': phone,
    'email': email,
    'address': address,
    'notes': notes,
    'status': status,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };
}

/// Create payload (`SupplierIn`).
class SupplierInput {
  const SupplierInput({
    required this.name,
    this.contactName,
    this.phone,
    this.email,
    this.address,
    this.notes,
  });

  final String name;
  final String? contactName;
  final String? phone;
  final String? email;
  final String? address;
  final String? notes;

  Map<String, dynamic> toJson() => {
    'name': name,
    if (contactName != null) 'contact_name': contactName,
    if (phone != null) 'phone': phone,
    if (email != null) 'email': email,
    if (address != null) 'address': address,
    if (notes != null) 'notes': notes,
  };
}

/// Partial update payload (`SupplierUpdate`).
class SupplierUpdate {
  const SupplierUpdate({
    this.name,
    this.contactName,
    this.phone,
    this.email,
    this.address,
    this.notes,
    this.status,
  });

  final String? name;
  final String? contactName;
  final String? phone;
  final String? email;
  final String? address;
  final String? notes;
  final String? status;

  Map<String, dynamic> toJson() => {
    if (name != null) 'name': name,
    if (contactName != null) 'contact_name': contactName,
    if (phone != null) 'phone': phone,
    if (email != null) 'email': email,
    if (address != null) 'address': address,
    if (notes != null) 'notes': notes,
    if (status != null) 'status': status,
  };
}

/// Many-to-many supplier↔product link (`SupplierProductOut`).
class SupplierProductLink {
  const SupplierProductLink({
    required this.id,
    required this.supplierId,
    required this.productId,
    this.supplierName,
    this.productName,
    this.productSku,
    this.supplierSku,
    this.supplierCost,
    this.leadTimeDays,
    required this.isPreferred,
  });

  factory SupplierProductLink.fromJson(Map<String, dynamic> json) =>
      SupplierProductLink(
        id: json['id'] as String,
        supplierId: json['supplier_id'] as String,
        productId: json['product_id'] as String,
        supplierName: json['supplier_name'] as String?,
        productName: json['product_name'] as String?,
        productSku: json['product_sku'] as String?,
        supplierSku: json['supplier_sku'] as String?,
        supplierCost: json['supplier_cost'] == null
            ? null
            : _toDouble(json['supplier_cost']),
        leadTimeDays: (json['lead_time_days'] as num?)?.toInt(),
        isPreferred: json['is_preferred'] as bool? ?? false,
      );

  final String id;
  final String supplierId;
  final String productId;
  final String? supplierName;
  final String? productName;
  final String? productSku;
  final String? supplierSku;
  final double? supplierCost;
  final int? leadTimeDays;
  final bool isPreferred;
}

class Category {
  const Category({
    required this.id,
    required this.storeId,
    this.parentId,
    required this.name,
    this.code,
    required this.status,
  });

  factory Category.fromJson(Map<String, dynamic> json) => Category(
    id: json['id'] as String,
    storeId: json['store_id'] as String,
    parentId: json['parent_id'] as String?,
    name: json['name'] as String,
    code: json['code'] as String?,
    status: json['status'] as String? ?? 'active',
  );

  final String id;
  final String storeId;
  final String? parentId;
  final String name;
  final String? code;
  final String status;

  bool get isActive => status == 'active';
}

/// Create payload (`CategoryIn`).
class CategoryInput {
  const CategoryInput({required this.name, this.code, this.parentId});

  final String name;
  final String? code;
  final String? parentId;

  Map<String, dynamic> toJson() => {
    'name': name,
    if (code != null) 'code': code,
    if (parentId != null) 'parent_id': parentId,
  };
}

/// Partial update payload (`CategoryUpdate`). Null means "no change".
class CategoryUpdate {
  const CategoryUpdate({
    this.name,
    this.code,
    this.parentId,
    this.clearParent = false,
    this.status,
  });

  final String? name;
  final String? code;
  final String? parentId;

  /// When true, send `parent_id: null` explicitly to clear an assigned parent
  /// during an edit (distinct from "field not supplied").
  final bool clearParent;
  final String? status;

  Map<String, dynamic> toJson() => {
    if (name != null) 'name': name,
    if (code != null) 'code': code,
    if (parentId != null)
      'parent_id': parentId
    else if (clearParent)
      'parent_id': null,
    if (status != null) 'status': status,
  };
}

/// `Page` envelope used by list endpoints: `{items, total, page, page_size, pages}`.
class Page<T> {
  const Page({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  factory Page.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) itemParser,
  ) => Page(
    items: [
      for (final item in (json['items'] as List? ?? []))
        itemParser(item as Map<String, dynamic>),
    ],
    total: (json['total'] as num?)?.toInt() ?? 0,
    page: (json['page'] as num?)?.toInt() ?? 1,
    pageSize: (json['page_size'] as num?)?.toInt() ?? 20,
  );

  final List<T> items;
  final int total;
  final int page;
  final int pageSize;

  bool get hasMore => items.isNotEmpty && page * pageSize < total;
}

/// External product data retrieved for an unknown barcode.
class BarcodeEnrichment {
  const BarcodeEnrichment({
    required this.barcode,
    this.name,
    this.brand,
    this.category,
    this.description,
    this.imageUrl,
    this.quantity,
  });

  factory BarcodeEnrichment.fromJson(Map<String, dynamic> json) =>
      BarcodeEnrichment(
        barcode: json['barcode'] as String? ?? '',
        name: json['name'] as String?,
        brand: json['brand'] as String?,
        category: json['category'] as String?,
        description: json['description'] as String?,
        imageUrl: json['image_url'] as String?,
        quantity: json['quantity'] as String?,
      );

  final String barcode;
  final String? name;
  final String? brand;
  final String? category;
  final String? description;
  final String? imageUrl;
  final String? quantity;

  bool get isEmpty =>
      name == null &&
      brand == null &&
      category == null &&
      description == null;
}

/// A product candidate discovered from an external source (e.g. Open Food Facts).
class ProductCandidate {
  const ProductCandidate({
    required this.name,
    this.brand,
    this.category,
    this.barcode,
    this.description,
    this.size,
    this.imageUrl,
    this.source = 'open_food_facts',
    this.confidence = 0.0,
  });

  factory ProductCandidate.fromJson(Map<String, dynamic> json) =>
      ProductCandidate(
        name: json['name'] as String? ?? '',
        brand: json['brand'] as String?,
        category: json['category'] as String?,
        barcode: json['barcode'] as String?,
        description: json['description'] as String?,
        size: json['size'] as String?,
        imageUrl: json['image_url'] as String?,
        source: json['source'] as String? ?? 'open_food_facts',
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      );

  final String name;
  final String? brand;
  final String? category;
  final String? barcode;
  final String? description;
  final String? size;
  final String? imageUrl;
  final String source;
  final double confidence;
}

/// Response from the product discovery endpoint.
class DiscoveryResult {
  const DiscoveryResult({
    required this.query,
    this.source = 'open_food_facts',
    this.candidates = const [],
  });

  factory DiscoveryResult.fromJson(Map<String, dynamic> json) =>
      DiscoveryResult(
        query: json['query'] as String? ?? '',
        source: json['source'] as String? ?? 'open_food_facts',
        candidates: [
          for (final c in (json['candidates'] as List? ?? []))
            ProductCandidate.fromJson(c as Map<String, dynamic>),
        ],
      );

  final String query;
  final String source;
  final List<ProductCandidate> candidates;

  bool get isEmpty => candidates.isEmpty;
}
