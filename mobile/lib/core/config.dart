import 'dart:io' show Platform;

/// Backend base URL. Override with
/// `flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000`.
/// Android emulator reaches the host's loopback through 10.0.2.2.
abstract final class AppConfig {
  static const _override = String.fromEnvironment('API_BASE_URL');

  static String get apiBaseUrl {
    if (_override.isNotEmpty) return _override;
    return Platform.isAndroid ? 'http://10.0.2.2:8000' : 'http://localhost:8000';
  }

  /// Design and PRD say "up to 10 MB".
  static const maxUploadBytes = 10 * 1024 * 1024;
}
