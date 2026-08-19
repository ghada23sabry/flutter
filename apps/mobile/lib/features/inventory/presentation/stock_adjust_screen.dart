import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/api_client.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/util/app_format.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_input.dart';
import '../data/inventory_api.dart';
import '../data/inventory_models.dart';

/// Stock adjustment via a signed delta. The resulting quantity is computed and
/// shown live; a reason is mandatory. Draining an expiry batch is optional.
class StockAdjustScreen extends StatefulWidget {
  const StockAdjustScreen({super.key, required this.api, required this.session, required this.product});

  final InventoryApi api;
  final SessionController session;
  final ProductStock product;

  @override
  State<StockAdjustScreen> createState() => _StockAdjustScreenState();
}

class _StockAdjustScreenState extends State<StockAdjustScreen> {
  final _formKey = GlobalKey<FormState>();
  final _deltaController = TextEditingController();
  final _reasonController = TextEditingController();
  String? _batchId;
  bool _submitting = false;
  String? _submitError;

  ProductStock get _product => widget.product;

  double get _delta => double.tryParse(_deltaController.text) ?? 0;

  double get _resulting => _product.quantity + _delta;

  @override
  void dispose() {
    _deltaController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      final result = await widget.api.adjustStock(
        store: widget.session.selectedStore!,
        productId: _product.productId,
        delta: _delta,
        reason: _reasonController.text.trim(),
        expiryBatchId: _batchId,
      );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = 'Cannot reach the server. Check your connection.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isNegative = _delta < 0;
    final canDrainBatch = isNegative && _product.expiryBatches.any((b) => b.quantity > 0);

    return Scaffold(
      appBar: AppBar(title: const Text('Adjust stock')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          children: [
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_product.productName, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'SKU ${_product.sku}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _ResultingRow(label: 'Current', value: _product.quantityLabel),
                  const SizedBox(height: AppSpacing.sm),
                  AppInput(
                    label: 'Adjustment (signed)',
                    hintText: isNegative ? 'e.g. -10' : 'e.g. +10',
                    controller: _deltaController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]'))],
                    onChanged: (_) => setState(() {}),
                    validator: (value) {
                      final v = double.tryParse(value ?? '');
                      if (v == null || v == 0) return 'Enter a non-zero adjustment.';
                      return null;
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _ResultingRow(
                    label: 'Resulting',
                    value: '${AppFormat.qty(_resulting)} ${_product.unit}'.trim(),
                    highlight: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppInput(
                    label: 'Reason',
                    hintText: 'e.g. Damaged goods, cycle count, restock',
                    controller: _reasonController,
                    maxLines: 2,
                    validator: (value) =>
                        (value == null || value.trim().isEmpty) ? 'A reason is required for the audit trail.' : null,
                  ),
                  if (canDrainBatch) ...[
                    const SizedBox(height: AppSpacing.md),
                    Text('Drain from an expiry batch', style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: AppSpacing.xs),
                    RadioGroup<String>(
                      groupValue: _batchId,
                      onChanged: (v) => setState(() => _batchId = v),
                      child: Column(
                        children: [
                          for (final b in _product.expiryBatches.where((b) => b.quantity > 0))
                            RadioListTile<String>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                '${b.batchCode ?? 'Unnamed'} · ${AppFormat.qty(b.quantity)} ${_product.unit} · expires ${b.expiryDate.year}-${b.expiryDate.month.toString().padLeft(2, '0')}-${b.expiryDate.day.toString().padLeft(2, '0')}',
                                style: Theme.of(context).textTheme.bodySmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              value: b.id,
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (_submitError != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                _submitError!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.error),
              ),
            ],
            const SizedBox(height: AppSpacing.xl),
            AppButton(
              label: 'Apply adjustment',
              loading: _submitting,
              onPressed: _submitting ? null : _submit,
              icon: Icons.check,
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultingRow extends StatelessWidget {
  const _ResultingRow({required this.label, required this.value, this.highlight = false});

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final valueStyle = highlight
        ? Theme.of(context).textTheme.titleLarge
        : Theme.of(context).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        Text(value, style: valueStyle),
      ],
    );
  }
}
