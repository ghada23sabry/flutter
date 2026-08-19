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
import 'zone_detail_screen.dart';
import 'zone_form_dialog.dart';

/// Store layout zones (e.g. `Frozen`, `Produce`, `Back office`).
class ZonesListScreen extends StatefulWidget {
  const ZonesListScreen({super.key, required this.api, required this.session});

  final InventoryApi api;
  final SessionController session;

  @override
  State<ZonesListScreen> createState() => _ZonesListScreenState();
}

class _ZonesListScreenState extends State<ZonesListScreen> {
  List<Zone>? _zones;
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
      final zones = await widget.api.listZones(
        store: widget.session.selectedStore!,
      );
      if (!mounted) return;
      setState(() {
        _zones = zones;
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

  Future<void> _openCreate() async {
    final created = await showZoneFormDialog(
      context: context,
      api: widget.api,
      session: widget.session,
    );
    if (created != null && mounted) _load();
  }

  Future<void> _openEdit(Zone zone) async {
    final updated = await showZoneFormDialog(
      context: context,
      api: widget.api,
      session: widget.session,
      existing: zone,
    );
    if (updated != null && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Zones')),
      body: _buildBody(),
      floatingActionButton: _canManage
          ? FloatingActionButton(
              tooltip: 'Add zone',
              onPressed: _openCreate,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingState(message: 'Loading zones…');
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    final zones = _zones!;
    if (zones.isEmpty) {
      return EmptyState(
        icon: Icons.grid_view_outlined,
        title: 'No zones yet',
        message: 'Zones group shelves by location so staff can find products.',
        action: _canManage
            ? AppButton(
                label: 'Add zone',
                onPressed: _openCreate,
                expand: false,
                icon: Icons.add,
              )
            : null,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(AppSpacing.lg),
        itemCount: zones.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
        itemBuilder: (context, index) {
          final zone = zones[index];
          return AppCard(
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ZoneDetailScreen(
                    api: widget.api,
                    session: widget.session,
                    zoneId: zone.id,
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
                  Icons.grid_view_outlined,
                  size: 22,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        zone.name,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      if (zone.code != null && zone.code!.isNotEmpty)
                        Text(
                          zone.code!,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                    ],
                  ),
                ),
                if (!zone.isActive)
                  const Padding(
                    padding: EdgeInsets.only(left: AppSpacing.sm),
                    child: Text(
                      'Inactive',
                      style: TextStyle(color: AppColors.neutral, fontSize: 12),
                    ),
                  ),
                if (_canManage)
                  IconButton(
                    tooltip: 'Edit zone',
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () => _openEdit(zone),
                  ),
                const Icon(Icons.chevron_right, size: 20),
              ],
            ),
          );
        },
      ),
    );
  }
}
