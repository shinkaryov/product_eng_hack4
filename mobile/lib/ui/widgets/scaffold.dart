import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/icons.dart';
import '../../core/theme/fd_colors.dart';
import '../../core/theme/fd_tokens.dart';
import '../../core/theme/fd_typography.dart';
import '../../data/api_client.dart';
import 'basics.dart';
import 'buttons.dart';

/// .fd-appbar — back button, centered 17 px title, trailing slot (44 px wide by default).
class FdAppBar extends StatelessWidget {
  const FdAppBar({super.key, this.title = '', this.trailing, this.onBack, this.showBack = true});
  final String title;
  final Widget? trailing;
  final VoidCallback? onBack;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: FdSpace.s2, vertical: FdSpace.s1),
      child: Row(children: [
        if (showBack)
          FdIconButton(FdIcons.back, size: 24, semanticLabel: 'Back', onPressed: onBack ?? () => _back(context))
        else
          const SizedBox(width: 44),
        const SizedBox(width: FdSpace.s2),
        Expanded(
          child: Semantics(
            header: true,
            child: Text(title, textAlign: TextAlign.center, style: FdType.appbarTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
        const SizedBox(width: FdSpace.s2),
        ConstrainedBox(constraints: const BoxConstraints(minWidth: 44), child: trailing ?? const SizedBox(width: 44)),
      ]),
    );
  }

  static void _back(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
    }
  }
}

/// A full screen: canvas background, optional app bar, scrolling body with the
/// design's padding (8 / 20 / 24) and 16 px gap, optional footer.
/// Set [withNav] on tab screens so content clears the floating bottom bar.
class FdPage extends StatelessWidget {
  const FdPage({
    super.key,
    this.appBar,
    required this.children,
    this.footer,
    this.withNav = false,
    this.gap = FdSpace.s4,
    this.topPadding = FdSpace.s2,
    this.onRefresh,
    this.overlay,
    this.background,
  });

  final Widget? appBar;
  final List<Widget> children;
  final Widget? footer;
  final bool withNav;
  final double gap;
  final double topPadding;
  final Future<void> Function()? onRefresh;

  /// Positioned layer above content (e.g. a toast).
  final Widget? overlay;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final bottomPad = withNav ? 104.0 : FdSpace.s6;
    Widget body = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(FdSpace.s5, topPadding, FdSpace.s5, bottomPad),
      children: [FdGapColumn(gap: gap, children: children)],
    );
    if (onRefresh != null) {
      body = RefreshIndicator(onRefresh: onRefresh!, color: c.brand, backgroundColor: c.surface, child: body);
    }
    return Scaffold(
      backgroundColor: background ?? c.canvas,
      body: SafeArea(
        bottom: footer == null && !withNav,
        child: Stack(children: [
          Column(children: [
            ?appBar,
            Expanded(child: body),
            ?footer,
          ]),
          ?overlay,
        ]),
      ),
    );
  }
}

/// .fd-footer — pinned bottom area with a top border.
class FdFooter extends StatelessWidget {
  const FdFooter({super.key, required this.children, this.border = true});
  final List<Widget> children;
  final bool border;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Container(
      padding: EdgeInsets.fromLTRB(FdSpace.s5, FdSpace.s3, FdSpace.s5, FdSpace.s5 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(color: c.canvas, border: border ? Border(top: BorderSide(color: c.line)) : null),
      child: FdGapColumn(gap: FdSpace.s2, children: children),
    );
  }
}

/// Opens a glass bottom sheet (.fd-sheet) with the grab handle.
Future<T?> showFdSheet<T>(BuildContext context, {required WidgetBuilder builder}) {
  final c = context.fd;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    barrierColor: c.scrim,
    elevation: 0,
    builder: (ctx) => FdSheet(child: Builder(builder: builder)),
  );
}

class FdSheet extends StatelessWidget {
  const FdSheet({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final mq = MediaQuery.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: mq.size.height * .92),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(FdRadius.xl)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: c.glassStrong,
              boxShadow: c.shadowSheet,
              border: Border(top: BorderSide(color: c.glassBorder)),
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(FdSpace.s6, FdSpace.s2, FdSpace.s6, FdSpace.s6 + mq.viewInsets.bottom + mq.padding.bottom),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: FdSpace.s2 + FdSpace.s4),
                    decoration: BoxDecoration(color: c.lineStrong, borderRadius: BorderRadius.circular(FdRadius.full)),
                  ),
                ),
                child,
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// .fd-toast — dark glass pill above the bottom bar, optional action (Undo / OK).
class FdToast {
  static OverlayEntry? _current;
  static Timer? _timer;

  static void show(BuildContext context, String text, {String? actionLabel, VoidCallback? onAction, bool aboveNav = true, Duration duration = const Duration(seconds: 4)}) {
    hide();
    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(
      builder: (ctx) => _ToastView(
        text: text,
        actionLabel: actionLabel,
        onAction: () {
          hide();
          onAction?.call();
        },
        bottom: (aboveNav ? 96.0 : 24.0) + MediaQuery.of(ctx).padding.bottom,
      ),
    );
    _current = entry;
    overlay.insert(entry);
    _timer = Timer(duration, hide);
  }

  static void hide() {
    _timer?.cancel();
    _current?.remove();
    _current = null;
  }

  /// Error toast for any thrown error.
  static void error(BuildContext context, Object e) =>
      show(context, e is ApiException ? e.message : 'Something went wrong. Try again.');
}

class _ToastView extends StatelessWidget {
  const _ToastView({required this.text, this.actionLabel, required this.onAction, required this.bottom});
  final String text;
  final String? actionLabel;
  final VoidCallback onAction;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Positioned(
      left: FdSpace.s4,
      right: FdSpace.s4,
      bottom: bottom,
      child: Semantics(
        liveRegion: true,
        child: Material(
          type: MaterialType.transparency,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(FdRadius.lg),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                padding: EdgeInsets.fromLTRB(FdSpace.s4, actionLabel == null ? FdSpace.s3 : 0, FdSpace.s2, actionLabel == null ? FdSpace.s3 : 0),
                decoration: BoxDecoration(color: c.glassInk, boxShadow: c.shadowRaised),
                child: Row(children: [
                  FdIcon(FdIcons.checkCircle, color: c.canvas),
                  const SizedBox(width: FdSpace.s3),
                  Expanded(child: Text(text, style: FdType.toast.copyWith(color: c.canvas))),
                  if (actionLabel != null)
                    GestureDetector(
                      onTap: onAction,
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 44),
                        padding: const EdgeInsets.symmetric(horizontal: FdSpace.s2),
                        alignment: Alignment.center,
                        child: Text(actionLabel!,
                            style: FdType.toast.copyWith(
                                color: c.canvas, fontWeight: FontWeight.w600, decoration: TextDecoration.underline, decorationColor: c.canvas)),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Centered loading state for a whole page body.
class FdLoading extends StatelessWidget {
  const FdLoading({super.key, this.label});
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: FdSpace.s12),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        FdSpinner(size: 24, color: c.brand),
        if (label != null) ...[const SizedBox(height: FdSpace.s3), Text(label!, style: FdType.meta.copyWith(color: c.inkSecondary))],
      ]),
    );
  }
}

/// Error state with Try again.
class FdErrorState extends StatelessWidget {
  const FdErrorState({super.key, required this.error, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final msg = error is ApiException ? (error as ApiException).message : 'Something went wrong. Try again.';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: FdSpace.s10),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        FdWell(FdIcons.alert, size: 56, radius: FdRadius.lg, background: c.dangerSoft, foreground: c.danger, iconSize: 24),
        const SizedBox(height: FdSpace.s3),
        Text(msg, textAlign: TextAlign.center, style: FdType.callout.copyWith(color: c.inkSecondary)),
        if (onRetry != null) ...[
          const SizedBox(height: FdSpace.s4),
          FdButton.secondary('Try again', icon: FdIcons.retry, onPressed: onRetry),
        ],
      ]),
    );
  }
}

/// Confirm dialog for destructive actions.
Future<bool> confirmFd(BuildContext context, {required String title, required String body, required String confirm, bool danger = true}) async {
  final c = context.fd;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body, style: FdType.body.copyWith(color: c.inkSecondary)),
      actionsPadding: const EdgeInsets.fromLTRB(FdSpace.s4, 0, FdSpace.s4, FdSpace.s4),
      actions: [
        FdButton.quiet('Cancel', onPressed: () => Navigator.of(ctx).pop(false)),
        FdButton(confirm, kind: danger ? FdButtonKind.danger : FdButtonKind.primary, onPressed: () => Navigator.of(ctx).pop(true)),
      ],
    ),
  );
  return ok ?? false;
}
