import 'package:flutter/material.dart';

import 'core/api_client.dart';
import 'core/config.dart';
import 'core/session_store.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/auth_gate.dart';

void main() {
  runApp(VisionStockApp(
    apiClient: ApiClient(baseUrl: AppConfig.apiBaseUrl),
    storage: const SecureSessionStorage(),
  ));
}

class VisionStockApp extends StatelessWidget {
  const VisionStockApp({super.key, required this.apiClient, required this.storage});

  final ApiClient apiClient;
  final SessionStorage storage;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VisionStock AI',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(Brightness.light),
      darkTheme: AppTheme.build(Brightness.dark),
      home: AuthGate(apiClient: apiClient, storage: storage),
    );
  }
}
