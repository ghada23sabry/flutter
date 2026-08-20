/// App-wide configuration.
abstract final class AppConfig {
  /// Backend base URL.
  ///
  /// Defaults to the production VisionStock API.
  /// Override at build/run time if needed:
  ///   flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://visionstock-api.fastapicloud.dev',
  );
  static const String appName = 'VisionStock AI';
}
