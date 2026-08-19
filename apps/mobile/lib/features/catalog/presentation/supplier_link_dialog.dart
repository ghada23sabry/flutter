import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_input.dart';
import '../data/catalog_models.dart';

/// Result of a supplier↔product link form.
class SupplierLinkValues {
  const SupplierLinkValues({this.supplierSku, this.supplierCost, this.leadTimeDays, this.isPreferred = false});

  final String? supplierSku;
  final double? supplierCost;
  final int? leadTimeDays;
  final bool isPreferred;
}

/// Form dialog for creating or editing a supplier↔product link.
///
/// [title] e.g. "Link supplier" or "Edit link". When [initial] is non-null the
/// form edits that link; otherwise it creates one.
class SupplierLinkDialog extends StatefulWidget {
  const SupplierLinkDialog({super.key, required this.title, this.initial});

  final String title;
  final SupplierProductLink? initial;

  @override
  State<SupplierLinkDialog> createState() => _SupplierLinkDialogState();
}

class _SupplierLinkDialogState extends State<SupplierLinkDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _sku;
  late final TextEditingController _cost;
  late final TextEditingController _leadTime;
  late bool _isPreferred;

  @override
  void initState() {
    super.initState();
    final link = widget.initial;
    _sku = TextEditingController(text: link?.supplierSku ?? '');
    _cost = TextEditingController(
      text: link?.supplierCost == null ? '' : _moneyInput(link!.supplierCost!),
    );
    _leadTime = TextEditingController(text: link?.leadTimeDays?.toString() ?? '');
    _isPreferred = link?.isPreferred ?? false;
  }

  @override
  void dispose() {
    _sku.dispose();
    _cost.dispose();
    _leadTime.dispose();
    super.dispose();
  }

  String _moneyInput(double value) => value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final costRaw = _cost.text.trim().replaceAll(',', '');
    Navigator.of(context).pop(
      SupplierLinkValues(
        supplierSku: _sku.text.trim().isEmpty ? null : _sku.text.trim(),
        supplierCost: costRaw.isEmpty ? null : double.parse(costRaw),
        leadTimeDays: _leadTime.text.trim().isEmpty ? null : int.parse(_leadTime.text.trim()),
        isPreferred: _isPreferred,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppInput(
                label: 'Supplier SKU',
                hintText: 'Code used by the supplier',
                controller: _sku,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: AppSpacing.md),
              AppInput(
                label: 'Supplier cost',
                hintText: 'Their price to you',
                controller: _cost,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textInputAction: TextInputAction.next,
                validator: (v) {
                  final value = v?.trim().replaceAll(',', '');
                  if (value == null || value.isEmpty) return null;
                  final parsed = double.tryParse(value);
                  if (parsed == null || parsed < 0) return 'Enter a valid amount';
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.md),
              AppInput(
                label: 'Lead time (days)',
                hintText: 'e.g. 7',
                controller: _leadTime,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: (v) {
                  final value = v?.trim();
                  if (value == null || value.isEmpty) return null;
                  final parsed = int.tryParse(value);
                  if (parsed == null || parsed < 0) return 'Enter a valid number of days';
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Preferred supplier'),
                subtitle: Text(
                  'Marked first in ordering suggestions',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
                value: _isPreferred,
                onChanged: (v) => setState(() => _isPreferred = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        AppButton(
          label: widget.initial == null ? 'Link' : 'Save',
          onPressed: _submit,
          expand: false,
        ),
      ],
    );
  }
}
