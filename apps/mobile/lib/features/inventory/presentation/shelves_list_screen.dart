import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/loading_state.dart';
import '../data/inventory_api.dart';
import '../data/inventory_models.dart';
import 'shelf_detail_screen.dart';

/// All shelves across every zone of the store.
class ShelvesListScreen extends StatefulWidget {
  const ShelvesListScreen({super.key, required this.api, required this.session});

  final InventoryApi api;
  final SessionController session;

  @override
  State<ShelvesListScreen> createState() => _ShelvesListScreenState();
}

class _ShelvesListScreenState extends State<ShelvesListScreen> {
  List<Shelf>? _shelves;
  bool _loading = true;
  String? _error;

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
      final shelves = await widget.api.listShelves(store: widget.session.selectedStore!);
      if (!mounted) return;
      setState(() {
        _shelves = shelves;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiException ? e.message : 'Cannot reach the server. Check your connection.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shelves')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingState(message: 'Loading shelves…');
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    final shelves = _shelves!;
    if (shelves.isEmpty) {
      return const EmptyState(
        icon: Icons.storefront_outlined,
        title: 'No shelves yet',
        message: 'Create a zone and add shelves to map products to locations.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(AppSpacing.lg),
        itemCount: shelves.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
        itemBuilder: (context, index) {
          final shelf = shelves[index];
          return AppCard(
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ShelfDetailScreen(api: widget.api, session: widget.session, shelfId: shelf.id)),
              );
              if (mounted) _load();
            },
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
            child: Row(
              children: [
                Icon(Icons.storefront_outlined, size: 22, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(shelf.label, style: Theme.of(context).textTheme.bodyLarge),
                      Text(
                        shelf.zoneName ?? 'Zone',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
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
