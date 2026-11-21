import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/add/add_sheet.dart';
import '../fd.dart';

/// Tab shell: floating glass bottom bar (.fd-bottomnav) — Home · Vault · + · Deadlines · Ask.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  void _go(int index) => navigationShell.goBranch(index, initialLocation: index == navigationShell.currentIndex);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(child: navigationShell),
        Positioned(
          left: FdSpace.s3,
          right: FdSpace.s3,
          bottom: FdSpace.s3 + MediaQuery.of(context).padding.bottom,
          child: FdBottomNav(current: navigationShell.currentIndex, onTap: _go, onAdd: () => showAddSheet(context)),
        ),
      ]),
    );
  }
}

class FdBottomNav extends StatelessWidget {
  const FdBottomNav({super.key, required this.current, required this.onTap, required this.onAdd});
  final int current;
  final ValueChanged<int> onTap;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final radius = BorderRadius.circular(FdRadius.xl);
    return Semantics(
      container: true,
      label: 'Main',
      child: DecoratedBox(
        decoration: BoxDecoration(borderRadius: radius, boxShadow: c.shadowNav),
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              height: FdSize.navBar,
              padding: const EdgeInsets.symmetric(horizontal: FdSpace.s2),
              decoration: BoxDecoration(color: c.glass, borderRadius: radius, border: Border.all(color: c.glassBorder)),
              child: Row(children: [
                _NavItem(icon: FdIcons.home, label: 'Home', selected: current == 0, onTap: () => onTap(0)),
                _NavItem(icon: FdIcons.grid, label: 'Vault', selected: current == 1, onTap: () => onTap(1)),
                Expanded(
                  child: Center(
                    child: Semantics(
                      button: true,
                      label: 'Add a document',
                      child: GestureDetector(
                        onTap: onAdd,
                        child: Container(
                          width: 48,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: c.brand, shape: BoxShape.circle, boxShadow: c.shadowButton),
                          child: FdIcon.lg(FdIcons.plus, color: c.onBrand),
                        ),
                      ),
                    ),
                  ),
                ),
                _NavItem(icon: FdIcons.calendar, label: 'Deadlines', selected: current == 2, onTap: () => onTap(2)),
                _NavItem(icon: FdIcons.chat, label: 'Ask', selected: current == 3, onTap: () => onTap(3)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.icon, required this.label, required this.selected, required this.onTap});
  final FdIcons icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final color = selected ? c.brand : c.inkSecondary;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            height: FdSize.tapMin,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              FdIcon.lg(icon, color: color),
              const SizedBox(height: 2),
              Text(label, style: FdType.nav.copyWith(color: color, fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
            ]),
          ),
        ),
      ),
    );
  }
}
