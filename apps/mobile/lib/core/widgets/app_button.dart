import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

enum AppButtonVariant { primary, secondary, outline, text }

enum AppButtonSize { small, medium, large }

class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.size = AppButtonSize.medium,
    this.loading = false,
    this.icon,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final AppButtonSize size;
  final bool loading;
  final IconData? icon;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isEnabled = onPressed != null && !loading;

    final padding = switch (size) {
      AppButtonSize.small => const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
      AppButtonSize.medium => const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.md,
        ),
      AppButtonSize.large => const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.lg,
        ),
    };

    final child = switch (size) {
      AppButtonSize.small => Theme.of(context).textTheme.labelMedium,
      AppButtonSize.medium => Theme.of(context).textTheme.labelLarge,
      AppButtonSize.large => Theme.of(context).textTheme.titleMedium,
    };

    final content = loading
        ? SizedBox(
            width: size == AppButtonSize.small ? 14 : 18,
            height: size == AppButtonSize.small ? 14 : 18,
            child: const CircularProgressIndicator(strokeWidth: 2.5),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18),
                const SizedBox(width: AppSpacing.sm),
              ],
              Flexible(child: Text(label, style: child)),
            ],
          );

    final button = switch (variant) {
      AppButtonVariant.primary => FilledButton(
          onPressed: isEnabled ? onPressed : null,
          style: FilledButton.styleFrom(
            padding: padding,
            disabledBackgroundColor: scheme.surfaceContainerHighest,
            disabledForegroundColor: scheme.onSurfaceVariant,
          ),
          child: content,
        ),
      AppButtonVariant.secondary => FilledButton.tonal(
          onPressed: isEnabled ? onPressed : null,
          style: FilledButton.styleFrom(
            padding: padding,
            disabledBackgroundColor: scheme.surfaceContainerHighest,
            disabledForegroundColor: scheme.onSurfaceVariant,
          ),
          child: content,
        ),
      AppButtonVariant.outline => OutlinedButton(
          onPressed: isEnabled ? onPressed : null,
          style: OutlinedButton.styleFrom(
            padding: padding,
            disabledForegroundColor: scheme.onSurfaceVariant,
          ),
          child: content,
        ),
      AppButtonVariant.text => TextButton(
          onPressed: isEnabled ? onPressed : null,
          style: TextButton.styleFrom(
            padding: padding,
            disabledForegroundColor: scheme.onSurfaceVariant,
          ),
          child: content,
        ),
    };

    if (!expand) {
      return button;
    }
    return SizedBox(width: double.infinity, child: button);
  }
}
