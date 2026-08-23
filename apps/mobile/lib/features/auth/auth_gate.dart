import 'package:flutter/material.dart';

import '../../core/api/auth_api.dart';
import '../../core/api_client.dart';
import '../../core/session.dart';
import '../../core/session_store.dart';
import '../home/app_shell.dart';
import 'login_screen.dart';

/// Routes to [LoginScreen] when unauthenticated, otherwise to [AppShell].
class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.apiClient, required this.storage});

  final ApiClient apiClient;
  final SessionStorage storage;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  late final SessionController _session;
  bool _restoring = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session = SessionController(storage: widget.storage, api: AuthApi(widget.apiClient));
    _restore();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _session.isAuthenticated) {
      // Proactively refresh in the background so the next request
      // doesn't have to wait for a 401 + retry cycle.
      _session.refreshOnResume();
    }
  }

  Future<void> _restore() async {
    await _session.restore();
    if (mounted) setState(() => _restoring = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_restoring) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        if (_session.isAuthenticated) {
          return AppShell(controller: _session, apiClient: widget.apiClient);
        }
        return LoginScreen(controller: _session);
      },
    );
  }
}
