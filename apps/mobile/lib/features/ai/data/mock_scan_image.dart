/// Deterministic M4-A test-image acquisition for AI count scans.
///
/// The byte contract is the documented `MockAIVisionPort` format:
///     image = b"VS-MOCK-1\n" + JSON of {"items": [DetectedItem, ...]}
///
/// The presentation layer only sees [ScanImageOption]s — it never encodes or
/// decodes images. M4-B replaces [MockScanImageSource] with a camera source
/// behind the same [ScanImageSource] contract, leaving the business flow
/// (create → process → review → confirm) untouched.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../../core/models/auth_models.dart';
import '../../inventory/data/inventory_api.dart';
import 'ai_models.dart';

/// Magic header of the documented mock contract.
const String mockImageMagic = 'VS-MOCK-1';

/// One detected item inside a mock image, mirroring `DetectedItem` (contract.py).
class MockScanItem {
  const MockScanItem({
    this.method = 'visual',
    this.detectedSku,
    this.detectedBarcode,
    this.confidence,
    required this.quantity,
    this.meta,
  });

  final String method;
  final String? detectedSku;
  final String? detectedBarcode;
  final double? confidence;
  final double quantity;
  final Map<String, dynamic>? meta;

  Map<String, dynamic> toJson() => {
    'method': method,
    'detected_sku': detectedSku,
    'detected_barcode': detectedBarcode,
    'confidence': confidence,
    'quantity': quantity,
    'meta': meta,
  };
}

/// Encode items into the deterministic mock-image byte contract.
Uint8List encodeMockImage(List<MockScanItem> items) {
  final payload = jsonEncode({
    'items': [for (final item in items) item.toJson()],
  });
  return Uint8List.fromList(utf8.encode('$mockImageMagic\n$payload'));
}

/// A scan image the user can select in the M4-A flow. M4-B camera captures
/// produce the same type without any change to the flow.
class ScanImageOption {
  const ScanImageOption({
    required this.id,
    required this.label,
    this.description,
    required this.bytes,
  });

  final String id;
  final String label;
  final String? description;
  final Uint8List bytes;
}

/// Acquisition boundary for scan images. M4-A ships [MockScanImageSource];
/// M4-B will add a camera-backed implementation behind this interface.
abstract interface class ScanImageSource {
  Future<List<ScanImageOption>> listOptions({required StoreInfo store});
}

/// Builds deterministic test scenes from the store's actual stock, so the mock
/// detections resolve to real products and the backend can reach `completed`.
class MockScanImageSource implements ScanImageSource {
  const MockScanImageSource(this.inventoryApi);

  final InventoryApi inventoryApi;

  @override
  Future<List<ScanImageOption>> listOptions({required StoreInfo store}) async {
    final page = await inventoryApi.listStock(store: store, pageSize: 8);
    final items = page.items;

    final matched = <MockScanItem>[
      for (var i = 0; i < items.length && i < 4; i++)
        MockScanItem(
          method: DetectionMethod.barcode,
          detectedBarcode: items[i].barcode,
          detectedSku: items[i].sku,
          confidence: 0.98,
          quantity: (i + 1).toDouble(),
        ),
    ];

    return [
      ScanImageOption(
        id: 'matched',
        label: 'Matched shelf scene',
        description:
            'High-confidence counts of the first stocked products — resolves to Completed.',
        bytes: encodeMockImage(matched),
      ),
      ScanImageOption(
        id: 'low-confidence',
        label: 'Low-confidence scene',
        description:
            'Same products at 0.45 confidence — routes to Needs review.',
        bytes: encodeMockImage([
          for (var i = 0; i < items.length && i < 2; i++)
            MockScanItem(
              method: DetectionMethod.visual,
              detectedBarcode: items[i].barcode,
              detectedSku: items[i].sku,
              confidence: 0.45,
              quantity: (i + 1).toDouble(),
            ),
        ]),
      ),
      ScanImageOption(
        id: 'unknown-item',
        label: 'Unknown-item scene',
        description: 'A barcode no product matches — routes to Needs review.',
        bytes: encodeMockImage([
          MockScanItem(
            method: DetectionMethod.barcode,
            detectedBarcode: '0000000000000',
            confidence: 0.98,
            quantity: 2,
          ),
        ]),
      ),
    ];
  }
}
