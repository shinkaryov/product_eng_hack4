import 'package:flutter/material.dart';

import '../../ui/fd.dart';

/// Shown while the stored session is restored.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Scaffold(
      backgroundColor: c.canvas,
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            FdIcon.lg(FdIcons.logo, color: c.brand),
            const SizedBox(width: FdSpace.s2),
            Text('FamilyDoc', style: FdType.bodyStrong.copyWith(fontSize: 18)),
          ]),
          const SizedBox(height: FdSpace.s6),
          FdSpinner(size: 24, color: c.brand),
        ]),
      ),
    );
  }
}
