import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/api_client.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_input.dart';
import '../data/inventory_api.dart';
import '../data/inventory_models.dart';

/// Create or edit an expiry batch.
///
/// - Create: full form (product pre-selected, quantity + expiry date required).
/// - Edit: only batch code + expiry date are editable (quantity moves stock).
class ExpiryBatchFormScreen extends StatefulWidget {
  const ExpiryBatchFormScreen({
    super.key,
    required this.api,
    required this.session,
    this.productId,
    this.productName,
    this.existing,
  }) : assert(existing != null || productId != null, 'Either create or edit mode must be set');

  final InventoryApi api;
  final SessionController session;
  final String? productId;
  final String? productName;
  final ExpiryBatch? existing;

  bool get isEdit => existing != null;

  @override
  State<ExpiryBatchFormScreen> createState() => _ExpiryBatchFormScreenState();
}

class _ExpiryBatchFormScreenState extends State<ExpiryBatchFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _quantityController;
  late final TextEditingController _batchController;
  late DateTime? _expiryDate;
  bool _submitting = false;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _quantityController = TextEditingController(text: existing == null ? '' : existing.quantity.toStringAsFixed(3));
    _batchController = TextEditingController(text: existing?.batchCode ?? '');
    _expiryDate = existing?.expiryDate;
  }

  @override
  void dispose() {
    _quantityController.dispose();
    _batchController.dispose();
    super.dispose();
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiryDate ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: now.add(const Duration(days: 1825)),
    );
    if (picked != null) setState(() => _expiryDate = picked);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      if (widget.isEdit) {
        final batch = await widget.api.updateExpiryBatch(
          store: widget.session.selectedStore!,
          batchId: widget.existing!.id,
          batchCode: _batchController.text.trim().isEmpty ? null : _batchController.text.trim(),
          expiryDate: _expiryDate,
        );
        if (!mounted) return;
        Navigator.of(context).pop(batch);
      } else {
        final batch = await widget.api.createExpiryBatch(
          store: widget.session.selectedStore!,
          productId: widget.productId!,
          quantity: double.parse(_quantityController.text),
          expiryDate: _expiryDate!,
          batchCode: _batchController.text.trim().isEmpty ? null : _batchController.text.trim(),
        );
        if (!mounted) return;
        Navigator.of(context).pop(batch);
      }
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
    return Scaffold(
      appBar: AppBar(title: Text(widget.isEdit ? 'Edit expiry batch' : 'Add expiry batch')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          children: [
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.productName != null) ...[
                    Text(widget.productName!, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: AppSpacing.lg),
                  ],
                  AppInput(
                    label: 'Quantity',
                    hintText: 'e.g. 24',
                    controller: _quantityController,
                    enabled: !widget.isEdit,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    validator: (value) {
                      if (widget.isEdit) return null;
                      final v = double.tryParse(value ?? '');
                      if (v == null || v <= 0) return 'Enter a positive quantity.';
                      return null;
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppInput(
                    label: 'Batch code (optional)',
                    hintText: 'e.g. LOT-2026-001',
                    controller: _batchController,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Expiry date', style: Theme.of(context).textTheme.bodyMedium),
                            const SizedBox(height: AppSpacing.xxs),
                            Text(
                              _expiryDate == null
                                  ? 'Required'
                                  : '${_expiryDate!.year}-${_expiryDate!.month.toString().padLeft(2, '0')}-${_expiryDate!.day.toString().padLeft(2, '0')}',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _pickExpiry,
                        icon: const Icon(Icons.calendar_today_outlined, size: 18),
                        label: const Text('Pick date'),
                      ),
                    ],
                  ),
                  if (widget.isEdit)
                    Text(
                      'Quantity is managed through stock adjustments and is not editable here.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
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
              label: widget.isEdit ? 'Save changes' : 'Add batch',
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
