import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/permissions.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/util/app_format.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/loading_state.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/inventory_api.dart';
import '../data/inventory_models.dart';
import 'expiry_batch_detail_screen.dart';
import 'movements_screen.dart';
import 'opening_stock_screen.dart';
import 'stock_adjust_screen.dart';

/// Full stock detail for one product: quantities, shelves, expiry batches and
/// recent movements, with opening/adjust actions.
class StockDetailScreen extends StatefulWidget {
  const StockDetailScreen({
    super.key,
    required this.api,
    required this.session,
    required this.productId,
    this.initialName,
  });

  final InventoryApi api;
  final SessionController session;
  final String productId;
  final String? initialName;

  @override
  State<StockDetailScreen> createState() => _StockDetailScreenState();
}

class _StockDetailScreenState extends State<StockDetailScreen> {
  ProductStock? _stock;
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
      final stock = await widget.api.getStockDetail(
        store: widget.session.selectedStore!,
        productId: widget.productId,
      );
      if (!mounted) return;
      setState(() {
        _stock = stock;
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

  Future<void> _openOpening() async {
    final result = await Navigator.of(context).push<ProductStock>(
      MaterialPageRoute(
        builder: (_) => OpeningStockScreen(
          api: widget.api,
          session: widget.session,
          productId: widget.productId,
          productName: _stock!.productName,
        ),
      ),
    );
    if (result != null && mounted) {
      _stock = result;
      setState(() {});
    }
  }

  Future<void> _openAdjust() async {
    final result = await Navigator.of(context).push<ProductStock>(
      MaterialPageRoute(
        builder: (_) => StockAdjustScreen(
          api: widget.api,
          session: widget.session,
          product: _stock!,
        ),
      ),
    );
    if (result != null && mounted) {
      _stock = result;
      setState(() {});
    }
  }

  void _openMovements() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MovementsScreen(
          api: widget.api,
          session: widget.session,
          productId: widget.productId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_stock?.productName ?? widget.initialName ?? 'Stock'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingState(message: 'Loading stock…');
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    final stock = _stock!;
    final scheme = Theme.of(context).colorScheme;
    final currency = widget.session.selectedStore!.currency;
    final canAdjust = widget.session.hasPermission(Permissions.inventoryAdjust);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          AppCard(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        stock.productName,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    StatusBadge(
                      label: StockStatus.label(stock.stockStatus),
                      status: switch (stock.stockStatus) {
                        StockStatus.lowStock => AppStatus.warning,
                        StockStatus.outOfStock => AppStatus.error,
                        _ => AppStatus.success,
                      },
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'SKU ${stock.sku}${stock.barcode != null ? ' · ${stock.barcode}' : ''}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      stock.quantityLabel,
                      style: Theme.of(context).textTheme.displaySmall,
                    ),
                    const Spacer(),
                    Text(
                      AppFormat.money(stock.value, currency: currency),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    _Metric(
                      label: 'Available',
                      value:
                          '${AppFormat.qty(stock.availableQuantity)} ${stock.unit}'
                              .trim(),
                    ),
                    _Metric(
                      label: 'Reserved',
                      value:
                          '${AppFormat.qty(stock.reservedQuantity)} ${stock.unit}'
                              .trim(),
                    ),
                    _Metric(
                      label: 'Reorder at',
                      value: AppFormat.qty(stock.reorderPoint),
                    ),
                  ],
                ),
                if (canAdjust) ...[
                  const SizedBox(height: AppSpacing.xl),
                  Row(
                    children: [
                      Expanded(
                        child: AppButton(
                          label: stock.hasOpening
                              ? 'Adjust stock'
                              : 'Set opening stock',
                          onPressed: stock.hasOpening
                              ? _openAdjust
                              : _openOpening,
                          icon: stock.hasOpening
                              ? Icons.tune
                              : Icons.playlist_add,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _SectionHeader(
            title: 'Recent movements',
            action: widget.session.hasPermission(Permissions.inventoryMovements)
                ? TextButton(
                    onPressed: _openMovements,
                    child: const Text('View all'),
                  )
                : null,
          ),
          if (stock.recentMovements.isEmpty)
            const _EmptyNote(message: 'No movements yet.')
          else
            for (final m in stock.recentMovements)
              _MovementTile(movement: m, currency: currency),
          if (stock.expiryBatches.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            _SectionHeader(title: 'Expiry batches'),
            for (final b in stock.expiryBatches)
              AppCard(
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ExpiryBatchDetailScreen(
                        api: widget.api,
                        session: widget.session,
                        batchId: b.id,
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
                      b.status == 'expired' ? Icons.event_busy : Icons.event,
                      size: 20,
                      color: b.status == 'expired'
                          ? AppColors.error
                          : AppColors.warning,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            b.batchCode == null || b.batchCode!.isEmpty
                                ? 'Unnamed batch'
                                : b.batchCode!,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          Text(
                            '${AppFormat.qty(b.quantity)} ${stock.unit} · expires ${b.expiryDate.year}-${b.expiryDate.month.toString().padLeft(2, '0')}-${b.expiryDate.day.toString().padLeft(2, '0')}',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    StatusBadge(
                      label: b.status == 'expired'
                          ? '${-b.daysRemaining}d past'
                          : '${b.daysRemaining}d',
                      status: b.status == 'expired'
                          ? AppStatus.error
                          : (b.status == 'near_expiry'
                                ? AppStatus.warning
                                : AppStatus.success),
                    ),
                  ],
                ),
              ),
          ],
          if (stock.shelves.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            _SectionHeader(title: 'Stored in'),
            for (final s in stock.shelves)
              AppCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.md,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.storefront_outlined,
                      size: 20,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.shelfLabel,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          Text(
                            '${s.zoneName}${s.shelfCode != null ? ' · ${s.shelfCode}' : ''}${s.isPrimary ? ' · primary' : ''}',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (stock.hasOpening)
            AppCard(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      'Reorder quantity: ${AppFormat.qty(stock.reorderQuantity)} ${stock.unit}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _MovementTile extends StatelessWidget {
  const _MovementTile({required this.movement, required this.currency});

  final MovementRef movement;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isIn = movement.quantityDelta >= 0;
    final color = isIn ? AppColors.success : AppColors.error;
    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isIn ? Icons.add : Icons.remove,
              size: 18,
              color: color,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  MovementType.label(movement.movementType),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (movement.notes != null && movement.notes!.isNotEmpty)
                  Text(
                    movement.notes!,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                AppFormat.signedQty(movement.quantityDelta),
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: color),
              ),
              if (movement.resultingQuantity != null)
                Text(
                  '→ ${AppFormat.qty(movement.resultingQuantity!)}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
