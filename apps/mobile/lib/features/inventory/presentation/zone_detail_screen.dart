import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/permissions.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/loading_state.dart';
import '../data/inventory_api.dart';
import '../data/inventory_models.dart';
import 'shelf_detail_screen.dart';
import 'shelf_form_dialog.dart';
import 'zone_form_dialog.dart';

/// Shelves inside one zone.
class ZoneDetailScreen extends StatefulWidget {
  const ZoneDetailScreen({
    super.key,
    required this.api,
    required this.session,
    required this.zoneId,
  });

  final InventoryApi api;
  final SessionController session;
  final String zoneId;

  @override
  State<ZoneDetailScreen> createState() => _ZoneDetailScreenState();
}

class _ZoneDetailScreenState extends State<ZoneDetailScreen> {
  Zone? _zone;
  List<Shelf>? _shelves;
  bool _loading = true;
  String? _error;

  bool get _canManage =>
      widget.session.hasPermission(Permissions.inventoryLayout);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<Object?>([
        widget.api.getZone(
          store: widget.session.selectedStore!,
          zoneId: widget.zoneId,
        ),
        widget.api.listShelves(
          store: widget.session.selectedStore!,
          zoneId: widget.zoneId,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _zone = results[0] as Zone;
        _shelves = results[1] as List<Shelf>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiException
            ? e.message
            : 'Cannot reach the server. Check your connection.';
      });
    }
  }

  Future<void> _openEditZone() async {
    final updated = await showZoneFormDialog(
      context: context,
      api: widget.api,
      session: widget.session,
      existing: _zone,
    );
    if (updated != null && mounted) _load();
  }

  Future<void> _openAddShelf() async {
    final created = await showShelfFormDialog(
      context: context,
      api: widget.api,
      session: widget.session,
      defaultZoneId: widget.zoneId,
    );
    if (created != null && mounted) _load();
  }

  Future<void> _openEditShelf(Shelf shelf) async {
    final updated = await showShelfFormDialog(
      context: context,
      api: widget.api,
      session: widget.session,
      existing: shelf,
    );
    if (updated != null && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_zone?.name ?? 'Zone'),
        actions: [
          if (_canManage && _zone != null)
            IconButton(
              tooltip: 'Edit zone',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _openEditZone,
            ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: _canManage
          ? FloatingActionButton(
              tooltip: 'Add shelf',
              onPressed: _openAddShelf,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _buildBody() {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return const LoadingState(message: 'Loading zone…');
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    final zone = _zone!;
    final shelves = _shelves!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(zone.name, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${shelves.length} shelves${zone.code != null && zone.code!.isNotEmpty ? ' · code ${zone.code}' : ''}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (shelves.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
              child: EmptyState(
                icon: Icons.storefront_outlined,
                title: 'No shelves in this zone',
                message: 'Add a shelf to map products to a location.',
                action: _canManage
                    ? AppButton(
                        label: 'Add shelf',
                        onPressed: _openAddShelf,
                        expand: false,
                        icon: Icons.add,
                      )
                    : null,
              ),
            )
          else
            for (final shelf in shelves)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: AppCard(
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ShelfDetailScreen(
                          api: widget.api,
                          session: widget.session,
                          shelfId: shelf.id,
                        ),
                      ),
                    );
                    if (mounted) _load();
                  },
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.md,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.storefront_outlined,
                        size: 22,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              shelf.label,
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                            if (shelf.code != null && shelf.code!.isNotEmpty)
                              Text(
                                shelf.code!,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                          ],
                        ),
                      ),
                      if (_canManage)
                        IconButton(
                          tooltip: 'Edit shelf',
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          onPressed: () => _openEditShelf(shelf),
                        ),
                      const Icon(Icons.chevron_right, size: 20),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
