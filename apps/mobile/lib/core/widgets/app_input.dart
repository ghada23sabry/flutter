import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Text field that participates in [Form] validation.
class AppInput extends StatelessWidget {
  const AppInput({
    super.key,
    this.label,
    this.hintText,
    this.errorText,
    this.icon,
    this.controller,
    this.initialValue,
    this.onChanged,
    this.keyboardType,
    this.textInputAction,
    this.obscureText = false,
    this.enabled = true,
    this.maxLines = 1,
    this.focusNode,
    this.autofocus = false,
    this.validator,
    this.inputFormatters,
  });

  final String? label;
  final String? hintText;
  final String? errorText;
  final IconData? icon;
  final TextEditingController? controller;
  final String? initialValue;
  final ValueChanged<String>? onChanged;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool obscureText;
  final bool enabled;
  final int maxLines;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? Function(String?)? validator;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextFormField(
      controller: controller,
      initialValue: controller == null ? initialValue : null,
      onChanged: onChanged,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      obscureText: obscureText,
      enabled: enabled,
      maxLines: maxLines,
      focusNode: focusNode,
      autofocus: autofocus,
      validator: validator,
      inputFormatters: inputFormatters,
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: enabled ? null : scheme.onSurfaceVariant,
          ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        errorText: errorText,
        prefixIcon: icon == null ? null : Icon(icon, size: 20),
        errorMaxLines: 2,
      ),
    );
  }
}
