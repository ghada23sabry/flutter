import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/permissions.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/util/app_format.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_input.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/loading_state.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/inventory_api.dart';
import '../data/inventory_models.dart';
import 'expiry_batch_form_screen.dart';

/// Details for one expiry batch: product, quantities, dates, risk status.
/// Editing and deletion are gated by `inventory.manage_expiry`.
class ExpiryBatchDetailScreen extends StatefulWidget {
  const ExpiryBatchDetailScreen({
    super.key,
    required this.api,
    required this.session,
    required this.batchId,
  });

  final InventoryApi api;
  final SessionController session;
  final String batchId;

  @override
  State<ExpiryBatchDetailScreen> createState() =>
      _ExpiryBatchDetailScreenState();
}

class _ExpiryBatchDetailScreenState extends State<ExpiryBatchDetailScreen> {
  ExpiryBatch? _batch;
  bool _loading = true;
  String? _error;

  bool get _canManage =>
      widget.session.hasPermission(Permissions.inventoryExpiry);

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
      final batch = await widget.api.getExpiryBatch(
        store: widget.session.selectedStore!,
        batchId: widget.batchId,
      );
      if (!mounted) return;
      setState(() {
        _batch = batch;
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

  Future<void> _openEdit() async {
    final updated = await Navigator.of(context).push<ExpiryBatch>(
      MaterialPageRoute(
        builder: (_) => ExpiryBatchFormScreen(
          api: widget.api,
          session: widget.session,
          existing: _batch,
        ),
      ),
    );
    if (updated != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Expiry batch updated')));
      _load();
    }
  }

  Future<void> _writeOff() async {
    final batch = _batch;
    if (batch == null) return;
    final result = await showDialog<({double quantity, String reason})>(
      context: context,
      builder: (_) => _WriteOffDialog(
        availableQuantity: batch.quantity,
        initialQuantity: batch.quantity,
      ),
    );
    if (result == null || !mounted) return;
    try {
      await widget.api.writeOffExpiryBatch(
        store: widget.session.selectedStore!,
        batchId: widget.batchId,
        quantity: result.quantity,
        reason: result.reason,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Stock written off')));
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete expiry batch?'),
        content: const Text(
          'Only batches with zero remaining quantity can be deleted. '
          'Drain the batch via Adjust Stock first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.api.deleteExpiryBatch(
        store: widget.session.selectedStore!,
        batchId: widget.batchId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Expiry batch deleted')));
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Expiry batch'),
        actions: [
          if (_canManage)
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _batch == null ? null : _openEdit,
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingState(message: 'Loading batch…');
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    final batch = _batch!;
    final scheme = Theme.of(context).colorScheme;
    final currency = widget.session.selectedStore!.currency;
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
                        batch.productName,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    StatusBadge(
                      label: batch.isExpired
                          ? 'Expired'
                          : (batch.isNearExpiry ? 'Near expiry' : 'Normal'),
                      status: batch.isExpired
                          ? AppStatus.error
                          : (batch.isNearExpiry
                                ? AppStatus.warning
                                : AppStatus.success),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'SKU ${batch.sku}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  '${AppFormat.qty(batch.quantity)} in batch',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Value ${AppFormat.money(batch.value, currency: currency)}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AppCard(
            child: Column(
              children: [
                _InfoRow(
                  label: 'Batch code',
                  value: batch.batchCode == null || batch.batchCode!.isEmpty
                      ? '—'
                      : batch.batchCode!,
                ),
                const Divider(height: 1),
                _InfoRow(label: 'Expiry date', value: batch.expiryLabel),
                const Divider(height: 1),
                _InfoRow(
                  label: 'Time left',
                  value: batch.isExpired
                      ? '${-batch.daysRemaining} days past'
                      : '${batch.daysRemaining} days',
                ),
                const Divider(height: 1),
                _InfoRow(
                  label: 'Received',
                  value:
                      '${batch.receivedAt.year}-${batch.receivedAt.month.toString().padLeft(2, '0')}-${batch.receivedAt.day.toString().padLeft(2, '0')}',
                ),
              ],
            ),
          ),
          if (_canManage) ...[
            if (batch.isExpired && batch.quantity > 0) ...[
              const SizedBox(height: AppSpacing.xl),
              AppButton(
                label: 'Write off stock',
                variant: AppButtonVariant.primary,
                onPressed: _writeOff,
                icon: Icons.delete_sweep_outlined,
              ),
            ],
            const SizedBox(height: AppSpacing.xl),
            AppButton(
              label: 'Edit batch',
              variant: AppButtonVariant.outline,
              onPressed: _openEdit,
              icon: Icons.edit_outlined,
            ),
            const SizedBox(height: AppSpacing.md),
            AppButton(
              label: 'Delete batch',
              variant: AppButtonVariant.outline,
              onPressed: batch.quantity > 0 ? null : _delete,
              icon: Icons.delete_outline,
            ),
            if (batch.quantity > 0) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Drain the batch to zero via Adjust Stock before deleting.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
          const SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }
}

class _WriteOffDialog extends StatefulWidget {
  const _WriteOffDialog({
    required this.availableQuantity,
    required this.initialQuantity,
  });

  final double availableQuantity;
  final double initialQuantity;

  @override
  State<_WriteOffDialog> createState() => _WriteOffDialogState();
}

class _WriteOffDialogState extends State<_WriteOffDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _quantityController;
  final _reasonController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _quantityController = TextEditingController(
      text: AppFormat.qty(widget.initialQuantity),
    );
  }

  @override
  void dispose() {
    _quantityController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final quantity = double.parse(_quantityController.text.trim());
    Navigator.of(
      context,
    ).pop((quantity: quantity, reason: _reasonController.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Write off stock?'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Removes ${AppFormat.qty(widget.availableQuantity)} available '
              'in this batch from inventory. This cannot be undone.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppInput(
              controller: _quantityController,
              label: 'Quantity',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              icon: Icons.delete_sweep_outlined,
              validator: (value) {
                final parsed = double.tryParse((value ?? '').trim());
                if (parsed == null || parsed <= 0) {
                  return 'Enter a quantity greater than zero';
                }
                if (parsed > widget.availableQuantity) {
                  return 'Cannot write off more than the available quantity';
                }
                return null;
              },
            ),
            const SizedBox(height: AppSpacing.md),
            AppInput(
              controller: _reasonController,
              label: 'Reason',
              hintText: 'e.g. Expired on shelf',
              maxLines: 2,
              textInputAction: TextInputAction.newline,
              validator: (value) =>
                  (value ?? '').trim().isEmpty ? 'Reason is required' : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: scheme.error),
          child: const Text('Write off'),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
