/// Presentation helpers shared across feature screens.
abstract final class AppFormat {
static const Map<String, String> _currencySymbols = {
  'USD': r'$',
  'EUR': '€',
  'GBP': '£',
  'CAD': r'$',
  'AUD': r'$',
  'JPY': '¥',
  'CNY': '¥',
  'INR': '₹',
  'BRL': r'R$',
  'MXN': r'$',
};

  /// Format a money value for the store currency, e.g. `$12.50`.
  static String money(double value, {String currency = 'USD'}) {
    final symbol = _currencySymbols[currency] ?? '$currency ';
    final rounded = value.toStringAsFixed(2);
    return '$symbol$rounded';
  }

  /// Whole number with thousands separators, e.g. `1,234`.
  static String integer(int value) {
    final digits = value.abs().toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return value < 0 ? '-$buffer' : buffer.toString();
  }

  /// Inventory quantity, trimming trailing zeros, e.g. `10`, `1.5`.
  static String qty(double value) {
    final fixed = value.toStringAsFixed(3);
    final trimmed = fixed.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    return trimmed.isEmpty ? '0' : trimmed;
  }

  /// Signed quantity for movements, e.g. `+10` / `-3`.
  static String signedQty(double value) => value < 0 ? '-${qty(-value)}' : '+${qty(value)}';

  /// Compact relative date, e.g. `12s ago`, `3d ago`.
 static String relativeDate(DateTime time) {
  final now = DateTime.now();
  final diff = now.difference(time);

  // Protect the UI from clock/timezone skew.
  if (diff.isNegative) {
    final future = time.difference(now);

    if (future.inSeconds < 60) {
      return 'just now';
    }

    if (future.inMinutes < 60) {
      return 'in ${future.inMinutes}m';
    }

    if (future.inHours < 24) {
      return 'in ${future.inHours}h';
    }

    if (future.inDays < 30) {
      return 'in ${future.inDays}d';
    }

    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  }

  if (diff.inSeconds < 60) {
    return '${diff.inSeconds}s ago';
  }

  if (diff.inMinutes < 60) {
    return '${diff.inMinutes}m ago';
  }

  if (diff.inHours < 24) {
    return '${diff.inHours}h ago';
  }

  if (diff.inDays < 30) {
    return '${diff.inDays}d ago';
  }

  return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
}
}
