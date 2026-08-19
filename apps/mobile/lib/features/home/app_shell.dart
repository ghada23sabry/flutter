import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme/app_tokens.dart';
import '../catalog/data/catalog_api.dart';
import '../catalog/presentation/category_list_screen.dart';
import '../catalog/presentation/product_list_screen.dart';
import '../catalog/presentation/scan_screen.dart';
import '../catalog/presentation/supplier_list_screen.dart';
import '../inventory/data/inventory_api.dart';
import '../inventory/presentation/inventory_overview_screen.dart';

/// Authenticated home: tabbed shell with store switcher and RBAC gating.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.controller,
    required this.apiClient,
  });

  final SessionController controller;
  final ApiClient apiClient;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final session = widget.controller;
        if (!session.isAuthenticated) {
          return const SizedBox.shrink();
        }

        final tabs = _visibleTabs(session);
        if (tabs.isEmpty) return _NoAccess(onLogout: session.logout);
        if (_tabIndex >= tabs.length) {
          _tabIndex = tabs.length - 1;
        }
        final tab = tabs[_tabIndex];

        return Scaffold(
          appBar: AppBar(
            title: Text(tab.label),
            actions: [
              _StoreSwitcher(session: session),
              IconButton(
                tooltip: 'Account',
                icon: const Icon(Icons.person_outline),
                onPressed: () => _openAccountSheet(session),
              ),
            ],
          ),
          body: IndexedStack(
            key: ValueKey(session.selectedStoreId),
            index: _tabIndex,
            children: [
              for (final t in tabs) t.build(session, widget.apiClient),
            ],
          ),
          bottomNavigationBar: tabs.length > 1
              ? NavigationBar(
                  selectedIndex: _tabIndex,
                  onDestinationSelected: (i) => setState(() => _tabIndex = i),
                  destinations: [
                    for (final t in tabs)
                      NavigationDestination(icon: Icon(t.icon), label: t.label),
                  ],
                )
              : null,
        );
      },
    );
  }

  List<_ShellTab> _visibleTabs(SessionController session) => [
    if (session.hasPermission(Permissions.productsView))
      _ShellTab(
        label: 'Products',
        icon: Icons.inventory_2_outlined,
        selectedIcon: Icons.inventory_2,
        build: (s, client) =>
            ProductListScreen(api: CatalogApi(client), session: s),
      ),
    if (session.hasPermission(Permissions.suppliersView))
      _ShellTab(
        label: 'Suppliers',
        icon: Icons.local_shipping_outlined,
        selectedIcon: Icons.local_shipping,
        build: (s, client) =>
            SupplierListScreen(api: CatalogApi(client), session: s),
      ),
    if (session.hasPermission(Permissions.categoriesView))
      _ShellTab(
        label: 'Categories',
        icon: Icons.category_outlined,
        selectedIcon: Icons.category,
        build: (s, client) =>
            CategoryListScreen(api: CatalogApi(client), session: s),
      ),
    if (session.hasPermission(Permissions.inventoryView))
      _ShellTab(
        label: 'Inventory',
        icon: Icons.warehouse_outlined,
        selectedIcon: Icons.warehouse,
        build: (s, client) =>
            InventoryOverviewScreen(api: InventoryApi(client), session: s),
      ),
    if (session.hasPermission(Permissions.productsView))
      _ShellTab(
        label: 'Scan',
        icon: Icons.qr_code_scanner,
        selectedIcon: Icons.qr_code_scanner,
        build: (s, client) => ScanScreen(api: CatalogApi(client), session: s),
      ),
  ];

  void _openAccountSheet(SessionController session) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _AccountSheet(
        session: session,
        onSignOut: () {
          Navigator.of(sheetContext).pop();
          session.logout();
        },
      ),
    );
  }
}

class _ShellTab {
  const _ShellTab({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.build,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function(SessionController, ApiClient) build;
}

class _StoreSwitcher extends StatelessWidget {
  const _StoreSwitcher({required this.session});

  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final store = session.selectedStore;
    if (store == null || session.stores.length <= 1) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Text(
            store?.name ?? '',
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: ActionChip(
          avatar: const Icon(Icons.storefront_outlined, size: 16),
          label: Text(store.name),
          onPressed: () => _showPicker(context),
        ),
      ),
    );
  }

  void _showPicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl,
                0,
                AppSpacing.xl,
                AppSpacing.md,
              ),
              child: Text(
                'Switch store',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            for (final store in session.stores)
              ListTile(
                leading: const Icon(Icons.storefront_outlined),
                title: Text(store.name),
                subtitle: Text('${store.currency} · ${store.timezone}'),
                trailing: store.id == session.selectedStoreId
                    ? Icon(
                        Icons.check_circle,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () {
                  session.selectStore(store.id);
                  Navigator.of(sheetContext).pop();
                },
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }
}

class _AccountSheet extends StatelessWidget {
  const _AccountSheet({required this.session, required this.onSignOut});

  final SessionController session;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final user = session.current?.user;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: scheme.primaryContainer,
              child: Text(
                user?.name.isNotEmpty == true
                    ? user!.name.characters.first.toUpperCase()
                    : '?',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              user?.name ?? 'Signed in',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              user?.email ?? '',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.xl),
            OutlinedButton.icon(
              onPressed: onSignOut,
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoAccess extends StatelessWidget {
  const _NoAccess({required this.onLogout});

  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('VisionStock AI')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.no_accounts_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: AppSpacing.lg),
              const Text(
                'No access',
                style: TextStyle(
                  fontSize: AppTypography.title,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              const Text(
                'Your role has no catalog permissions in this workspace.',
              ),
              const SizedBox(height: AppSpacing.xl),
              OutlinedButton.icon(
                onPressed: onLogout,
                icon: const Icon(Icons.logout, size: 18),
                label: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
