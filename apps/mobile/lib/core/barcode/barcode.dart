/// Barcode scanning foundation.
///
/// Camera capture is not wired yet (Android-first build deferred); the app
/// currently exposes manual barcode entry through [BarcodeScanner.manual]
/// and a pure [normalizeBarcode] used both client-side and by the backend
/// lookup endpoint.
library;

/// A barcode read from a physical scan or manual entry.
class BarcodeScanResult {
  const BarcodeScanResult({required this.barcode, this.symbology});

  final String barcode;

  /// e.g. `EAN-13`, `UPC-A`, `QR`; null when entered manually.
  final String? symbology;
}

/// Abstraction over hardware scanners. Replace the [manual] implementation
/// with a camera-based one (camera plugin) when the APK build lands.
abstract interface class BarcodeScanner {
  /// Whether camera capture is available on this build.
  bool get hardwareAvailable => false;

  Future<BarcodeScanResult?> scan();

  /// Manual keypad entry — always available, used as the fallback.
  static Future<BarcodeScanResult?> manual() async => null;
}

/// Trim, collapse all whitespace runs, uppercase — mirrors the backend's
/// `normalize_barcode` (`" ".join(value.split()).upper()`) so scanner input
/// always matches stored values.
String normalizeBarcode(String raw) =>
    raw.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).join(' ').toUpperCase();

/// True when the value looks like a scannable barcode (>= 6 alphanumeric).
bool isValidBarcode(String raw) {
  final normalized = normalizeBarcode(raw);
  return normalized.length >= 6 && RegExp(r'^[A-Z0-9]+$').hasMatch(normalized);
}
