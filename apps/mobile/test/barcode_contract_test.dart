import 'package:flutter_test/flutter_test.dart';

import 'package:visionstock_mobile/core/barcode/barcode.dart';
import 'package:visionstock_mobile/features/catalog/data/catalog_models.dart';

/// Locks the barcode contract so the future camera scanner reuses this exact
/// pipeline: Camera → Decode → normalizeBarcode → Catalog API lookup → Product.
void main() {
  test('normalizeBarcode mirrors the backend normalize_barcode semantics', () {
    // collapse all whitespace runs, trim, uppercase — same as
    // `" ".join(value.split()).upper()` in services/api catalog_service.py.
    expect(normalizeBarcode('  m21-qa-bcode-1  '), 'M21-QA-BCODE-1');
    expect(normalizeBarcode(' m21\tqa\nbcode-1 '), 'M21 QA BCODE-1');
    expect(normalizeBarcode('UPC123456'), 'UPC123456');
    expect(normalizeBarcode('   '), '');
  });

  test(
    'isValidBarcode accepts scannable values and rejects short/junk input',
    () {
      expect(isValidBarcode(' 9780201379624 '), isTrue);
      expect(isValidBarcode('M21-QA-BCODE-1'), isFalse); // '-' not in [A-Z0-9]
      expect(isValidBarcode('123'), isFalse);
      expect(isValidBarcode(''), isFalse);
      expect(isValidBarcode('   abc   '), isFalse);
    },
  );

  test('ProductUpdate omits barcode unless set or explicitly cleared', () {
    const untouched = ProductUpdate();
    expect(untouched.toJson().containsKey('barcode'), isFalse);

    const setBarcode = ProductUpdate(barcode: '2100000000123');
    expect(setBarcode.toJson()['barcode'], '2100000000123');

    // Clearing is distinct from "field not supplied": explicit null is sent.
    const cleared = ProductUpdate(clearBarcode: true);
    expect(cleared.toJson().containsKey('barcode'), isTrue);
    expect(cleared.toJson()['barcode'], isNull);

    // An explicit value wins over the clear flag.
    const both = ProductUpdate(barcode: 'X', clearBarcode: true);
    expect(both.toJson()['barcode'], 'X');
  });
}
