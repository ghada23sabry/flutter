import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

enum AppStatus { success, warning, error, info, neutral }

class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    this.status = AppStatus.neutral,
  });

  final String label;
  final AppStatus status;

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = switch (status) {
      AppStatus.success => (AppColors.successContainer, AppColors.onSuccessContainer),
      AppStatus.warning => (AppColors.warningContainer, AppColors.onWarningContainer),
      AppStatus.error => (AppColors.errorContainer, AppColors.onErrorContainer),
      AppStatus.info => (AppColors.infoContainer, AppColors.onInfoContainer),
      AppStatus.neutral => (
          Theme.of(context).colorScheme.surfaceContainerHighest,
          Theme.of(context).colorScheme.onSurfaceVariant,
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: foreground),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
