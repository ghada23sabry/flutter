import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/permissions.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/util/app_format.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/loading_state.dart';
import '../../../core/widgets/status_badge.dart';
import '../../catalog/data/catalog_api.dart';
import '../../catalog/data/catalog_models.dart' show Product;
import '../data/inventory_api.dart';
import '../data/inventory_models.dart';
import 'expiry_batch_detail_screen.dart';
import 'expiry_batch_form_screen.dart';
import 'product_picker_screen.dart';

/// Expiry batch overview, sorted by expiry (soonest first) with risk
/// grouping: expired → near expiry → normal.
class ExpiryListScreen extends StatefulWidget {
  const ExpiryListScreen({
    super.key,
    required this.api,
    required this.session,
    this.initialStatus,
  });

  final InventoryApi api;
  final SessionController session;

  /// Initial status filter (e.g. `near_expiry` / `expired`) when opened from
  /// the overview summary tiles; `null` shows all batches.
  final String? initialStatus;

  @override
  State<ExpiryListScreen> createState() => _ExpiryListScreenState();
}

class _ExpiryListScreenState extends State<ExpiryListScreen> {
  List<ExpiryBatch>? _batches;
  bool _loading = true;
  String? _error;
  late String? _statusFilter;
  bool _hideDrained = false;

  bool get _canManage =>
      widget.session.hasPermission(Permissions.inventoryExpiry);

  @override
  void initState() {
    super.initState();
    _statusFilter = widget.initialStatus;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final batches = await widget.api.listExpiryBatches(
        store: widget.session.selectedStore!,
        status: _statusFilter,
      );
      if (!mounted) return;
      setState(() {
        _batches = batches;
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

  Future<void> _openAdd() async {
    final product = await Navigator.of(context).push<Product?>(
      MaterialPageRoute(
        builder: (_) => ProductPickerScreen(
          api: CatalogApi(widget.api.client),
          session: widget.session,
        ),
      ),
    );
    if (product == null || !mounted) return;
    final created = await Navigator.of(context).push<ExpiryBatch>(
      MaterialPageRoute(
        builder: (_) => ExpiryBatchFormScreen(
          api: widget.api,
          session: widget.session,
          productId: product.id,
          productName: product.name,
        ),
      ),
    );
    if (created != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Expiry batch added')));
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Expiry tracking')),
      body: _buildBody(),
      floatingActionButton: _canManage
          ? FloatingActionButton(
              tooltip: 'Add expiry batch',
              onPressed: _openAdd,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingState(message: 'Loading expiry batches…');
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    final batches = _batches!;
    final scheme = Theme.of(context).colorScheme;
    final visible = _hideDrained
        ? [
            for (final b in batches)
              if (b.quantity > 0) b,
          ]
        : batches;
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.xs,
            ),
            children: [
              _FilterChip(
                'All',
                null,
                _statusFilter,
                () => setState(() {
                  _statusFilter = null;
                  _load();
                }),
              ),
              const SizedBox(width: AppSpacing.sm),
              _FilterChip(
                'Expired',
                'expired',
                _statusFilter,
                () => setState(() {
                  _statusFilter = 'expired';
                  _load();
                }),
              ),
              const SizedBox(width: AppSpacing.sm),
              _FilterChip(
                'Near expiry',
                'near_expiry',
                _statusFilter,
                () => setState(() {
                  _statusFilter = 'near_expiry';
                  _load();
                }),
              ),
              const SizedBox(width: AppSpacing.sm),
              _FilterChip(
                'Normal',
                'normal',
                _statusFilter,
                () => setState(() {
                  _statusFilter = 'normal';
                  _load();
                }),
              ),
            ],
          ),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          title: const Text('Hide drained batches'),
          subtitle: Text(
            'Hide batches with zero quantity',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          value: _hideDrained,
          onChanged: (v) => setState(() => _hideDrained = v),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Text(
            '${visible.length} batches',
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: visible.isEmpty
              ? const EmptyState(
                  icon: Icons.event_note_outlined,
                  title: 'No expiry batches',
                  message:
                      'Add a batch with a quantity and expiry date to track it here.',
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    itemCount: visible.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, index) {
                      final batch = visible[index];
                      return AppCard(
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ExpiryBatchDetailScreen(
                                api: widget.api,
                                session: widget.session,
                                batchId: batch.id,
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
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    batch.productName,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyLarge,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: AppSpacing.xs),
                                  Text(
                                    '${batch.batchCode ?? 'Unnamed'} · ${AppFormat.qty(batch.quantity)}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                  ),
                                  Text(
                                    'Expires ${batch.expiryLabel}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: batch.isExpired
                                              ? AppColors.error
                                              : (batch.isNearExpiry
                                                    ? AppColors.warning
                                                    : scheme.onSurfaceVariant),
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            StatusBadge(
                              label: batch.isExpired
                                  ? '${-batch.daysRemaining}d past'
                                  : '${batch.daysRemaining}d left',
                              status: batch.isExpired
                                  ? AppStatus.error
                                  : (batch.isNearExpiry
                                        ? AppStatus.warning
                                        : AppStatus.success),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip(this.label, this.value, this.selected, this.onTap);

  final String label;
  final String? value;
  final String? selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: FilterChip(
        label: Text(label),
        selected: value == selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
      ),
    );
  }
}
