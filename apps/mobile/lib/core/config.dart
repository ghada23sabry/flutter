/// App-wide configuration.
abstract final class AppConfig {
  /// Backend base URL.
  ///
  /// Default targets localhost (`127.0.0.1`) which works on both:
  ///   - Real devices via `adb reverse tcp:8000 tcp:8000`
  ///   - Emulators (127.0.0.1 is forwarded to host)
  /// Override at build/run time:
  ///   flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );

  static const String appName = 'VisionStock AI';
}
