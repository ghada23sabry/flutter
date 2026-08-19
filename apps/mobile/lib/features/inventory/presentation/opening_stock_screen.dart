import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/api_client.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_input.dart';
import '../data/inventory_api.dart';

/// One-time opening stock entry for a product (create `OPENING` movement).
class OpeningStockScreen extends StatefulWidget {
  const OpeningStockScreen({
    super.key,
    required this.api,
    required this.session,
    required this.productId,
    required this.productName,
  });

  final InventoryApi api;
  final SessionController session;
  final String productId;
  final String productName;

  @override
  State<OpeningStockScreen> createState() => _OpeningStockScreenState();
}

class _OpeningStockScreenState extends State<OpeningStockScreen> {
  final _formKey = GlobalKey<FormState>();
  final _quantityController = TextEditingController();
  final _batchController = TextEditingController();
  DateTime? _expiryDate;
  bool _submitting = false;
  String? _submitError;

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
      firstDate: now,
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
      final result = await widget.api.setOpeningStock(
        store: widget.session.selectedStore!,
        productId: widget.productId,
        quantity: double.parse(_quantityController.text),
        batchCode: _batchController.text.trim().isEmpty ? null : _batchController.text.trim(),
        expiryDate: _expiryDate,
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
    return Scaffold(
      appBar: AppBar(title: const Text('Set opening stock')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          children: [
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.productName, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: AppSpacing.lg),
                  AppInput(
                    label: 'Opening quantity',
                    hintText: 'e.g. 50',
                    controller: _quantityController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    validator: (value) {
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
                  Text(
                    'This writes the quantity as a one-time OPENING movement. Set it only once — use Adjust stock afterwards.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppCard(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Expiry date (optional)', style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          _expiryDate == null
                              ? 'None'
                              : '${_expiryDate!.year}-${_expiryDate!.month.toString().padLeft(2, '0')}-${_expiryDate!.day.toString().padLeft(2, '0')}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _pickExpiry,
                    icon: const Icon(Icons.calendar_today_outlined, size: 18),
                    label: Text(_expiryDate == null ? 'Pick date' : 'Change'),
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
              label: 'Save opening stock',
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
