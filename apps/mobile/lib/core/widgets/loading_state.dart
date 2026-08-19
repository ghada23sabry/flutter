import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

class LoadingState extends StatelessWidget {
  const LoadingState({
    super.key,
    this.message,
    this.expand = true,
  });

  final String? message;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const CircularProgressIndicator(),
        if (message != null) ...[
          const SizedBox(height: AppSpacing.lg),
          Text(
            message!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
    if (!expand) {
      return content;
    }
    return Center(child: content);
  }
}
