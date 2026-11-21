import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/theme/app_theme.dart';
import '../../ui/fd.dart';
import 'add_sheet.dart';
import 'scan_session.dart';

enum _Cam { loading, ready, noCamera, denied, failed }

/// Full-screen camera scanner (design Scan). Each photo becomes a page of the
/// current scan session; after a shot the user checks pages on Scan review.
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> with WidgetsBindingObserver {
  // The scanner is dark in the design regardless of the app theme.
  static final _darkTheme = buildTheme(Brightness.dark);

  CameraController? _controller;
  _Cam _cam = _Cam.loading;
  bool _taking = false;
  bool _stoppedByLifecycle = false;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gen++;
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ctrl = _controller;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      // Permission prompts also make the app inactive: only release a running camera.
      if (ctrl == null || !ctrl.value.isInitialized) return;
      _gen++;
      _controller = null;
      _stoppedByLifecycle = true;
      if (mounted) setState(() => _cam = _Cam.loading);
      ctrl.dispose();
    } else if (state == AppLifecycleState.resumed && _stoppedByLifecycle) {
      _stoppedByLifecycle = false;
      _init();
    }
  }

  Future<void> _init() async {
    final gen = ++_gen;
    if (mounted) setState(() => _cam = _Cam.loading);
    CameraController? ctrl;
    try {
      final cams = await availableCameras();
      if (gen != _gen || !mounted) return;
      if (cams.isEmpty) {
        setState(() => _cam = _Cam.noCamera);
        return;
      }
      final cam = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      ctrl = CameraController(cam, ResolutionPreset.veryHigh, enableAudio: false);
      await ctrl.initialize();
      if (gen != _gen || !mounted) {
        await ctrl.dispose();
        return;
      }
      _controller = ctrl;
      setState(() => _cam = _Cam.ready);
    } on CameraException catch (e) {
      await ctrl?.dispose();
      if (gen != _gen || !mounted) return;
      final denied = e.code.startsWith('CameraAccess');
      setState(() => _cam = denied ? _Cam.denied : _Cam.failed);
    } catch (_) {
      await ctrl?.dispose();
      if (gen != _gen || !mounted) return;
      setState(() => _cam = _Cam.failed);
    }
  }

  Future<void> _shoot() async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized || _taking || ctrl.value.isTakingPicture) return;
    setState(() => _taking = true);
    try {
      final shot = await ctrl.takePicture();
      final bytes = await shot.readAsBytes();
      unawaited(File(shot.path).delete().then((_) {}, onError: (_) {}));
      ref.read(scanSessionProvider.notifier).capture(bytes);
    } catch (_) {
      if (mounted) {
        setState(() => _taking = false);
        FdToast.show(context, 'The photo didn’t work. Try again.', aboveNav: false);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _taking = false);
    await _openReview();
  }

  Future<void> _openReview() async {
    try {
      await _controller?.pausePreview();
    } catch (_) {}
    if (!mounted) return;
    final savedId = await context.push<String>(Routes.scanReview);
    if (!mounted) return;
    if (savedId != null) {
      context.pushReplacement(Routes.processing(savedId));
      return;
    }
    try {
      await _controller?.resumePreview();
    } catch (_) {}
  }

  /// Leaves the scanner, asking first when pages would be lost.
  Future<void> _leave({bool thenUpload = false}) async {
    final session = ref.read(scanSessionProvider);
    if (!session.isEmpty) {
      final n = session.pages.length;
      final ok = await confirmFd(
        context,
        title: 'Discard ${plural(n, 'page')}?',
        body: 'The pages you scanned won’t be saved.',
        confirm: 'Discard',
      );
      if (!ok || !mounted) return;
    }
    ref.read(scanSessionProvider.notifier).clear();
    final rootCtx = rootNavigatorKey.currentContext;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.home);
    }
    if (thenUpload && rootCtx != null && rootCtx.mounted) {
      unawaited(showAddSheet(rootCtx));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(scanSessionProvider);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Theme(
        data: _darkTheme,
        child: Builder(builder: (context) {
          final c = context.fd;
          final mq = MediaQuery.of(context);
          final ctrl = _controller;
          final ready = _cam == _Cam.ready && ctrl != null && ctrl.value.isInitialized;
          return PopScope(
            canPop: session.isEmpty,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _leave();
            },
            child: Scaffold(
              backgroundColor: c.camera,
              body: Stack(fit: StackFit.expand, children: [
                if (ready) Positioned.fill(child: _Preview(ctrl)),
                if (ready)
                  Positioned(
                    top: mq.padding.top + 76,
                    bottom: mq.padding.bottom + 166,
                    left: FdSpace.s8,
                    right: FdSpace.s8,
                    child: IgnorePointer(child: CustomPaint(painter: _FramePainter(c.onCamera))),
                  ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(FdSpace.s4, FdSpace.s4, FdSpace.s4, FdSpace.s10),
                    child: Column(children: [
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        FdIconButton(FdIcons.close, size: 24, color: c.onCamera, semanticLabel: 'Close scanner', onPressed: _leave),
                        Text('Page ${session.currentPageNumber}', style: FdType.callout.copyWith(color: c.onCamera)),
                        FdIconButton(FdIcons.upload,
                            size: 24, color: c.onCamera, semanticLabel: 'Upload a file instead', onPressed: () => _leave(thenUpload: true)),
                      ]),
                      Expanded(child: ready ? _ReadyControls(taking: _taking, onShoot: _shoot) : _body(c)),
                    ]),
                  ),
                ),
              ]),
            ),
          );
        }),
      ),
    );
  }

  Widget _body(FdColors c) {
    if (_cam == _Cam.loading || _cam == _Cam.ready) {
      return Center(child: FdSpinner(size: 24, color: c.onCamera));
    }
    final (title, body) = switch (_cam) {
      _Cam.noCamera => ('No camera available', 'This device doesn’t have a camera we can use. Upload a file instead.'),
      _Cam.denied => ('Camera access is off', 'Allow FamilyDoc to use the camera in Settings, or upload a file instead.'),
      _ => ('The camera didn’t start', 'Try again, or upload a file instead.'),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: FdSpace.s4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          FdIcon.lg(FdIcons.scan, color: c.onCamera),
          const SizedBox(height: FdSpace.s3),
          Semantics(
            header: true,
            child: Text(title, textAlign: TextAlign.center, style: FdType.headline.copyWith(color: c.onCamera)),
          ),
          const SizedBox(height: FdSpace.s2),
          Text(body, textAlign: TextAlign.center, style: FdType.callout.copyWith(color: c.onCamera.withValues(alpha: .8))),
          const SizedBox(height: FdSpace.s6),
          FdButton('Upload a file instead', icon: FdIcons.upload, onPressed: () => _leave(thenUpload: true)),
          if (_cam != _Cam.noCamera) ...[
            const SizedBox(height: FdSpace.s2),
            FdButton.quiet('Try again', icon: FdIcons.retry, foreground: c.onCamera, onPressed: _init),
          ],
        ]),
      ),
    );
  }
}

/// Hint chip in the middle, shutter at the bottom (the design's space-between column).
class _ReadyControls extends StatelessWidget {
  const _ReadyControls({required this.taking, required this.onShoot});
  final bool taking;
  final VoidCallback onShoot;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      const SizedBox.shrink(),
      Container(
        constraints: const BoxConstraints(maxWidth: 270),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(color: c.cameraChip, borderRadius: BorderRadius.circular(FdRadius.lg)),
        child: Text(
          'Fit the page inside the frame. Tap the button when it’s steady.',
          textAlign: TextAlign.center,
          style: FdType.chip.copyWith(color: c.onCamera),
        ),
      ),
      Semantics(
        button: true,
        enabled: !taking,
        label: 'Take photo',
        child: GestureDetector(
          onTap: taking ? null : onShoot,
          child: Container(
            width: 72,
            height: 72,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: c.onCamera, width: 4)),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: taking ? 48 : 56,
              height: taking ? 48 : 56,
              decoration: BoxDecoration(shape: BoxShape.circle, color: c.onCamera.withValues(alpha: taking ? .6 : 1)),
            ),
          ),
        ),
      ),
    ]);
  }
}

/// Live preview cropped to fill the screen.
class _Preview extends StatelessWidget {
  const _Preview(this.controller);
  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.previewSize;
    if (size == null) return Center(child: CameraPreview(controller));
    final portrait = MediaQuery.of(context).orientation == Orientation.portrait;
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: portrait ? size.height : size.width,
          height: portrait ? size.width : size.height,
          child: CameraPreview(controller),
        ),
      ),
    );
  }
}

/// Four white 3 px L-corners (32 px arms, radius 12) of .fd-scanner__frame.
class _FramePainter extends CustomPainter {
  _FramePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const arm = 32.0, r = 12.0, w = 3.0, h = w / 2;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.butt;
    final sw = size.width, sh = size.height;
    // top-left
    canvas.drawPath(
        Path()
          ..moveTo(h, arm)
          ..lineTo(h, r)
          ..arcToPoint(const Offset(r, h), radius: const Radius.circular(r - h))
          ..lineTo(arm, h),
        p);
    // top-right
    canvas.drawPath(
        Path()
          ..moveTo(sw - arm, h)
          ..lineTo(sw - r, h)
          ..arcToPoint(Offset(sw - h, r), radius: const Radius.circular(r - h))
          ..lineTo(sw - h, arm),
        p);
    // bottom-right
    canvas.drawPath(
        Path()
          ..moveTo(sw - h, sh - arm)
          ..lineTo(sw - h, sh - r)
          ..arcToPoint(Offset(sw - r, sh - h), radius: const Radius.circular(r - h))
          ..lineTo(sw - arm, sh - h),
        p);
    // bottom-left
    canvas.drawPath(
        Path()
          ..moveTo(arm, sh - h)
          ..lineTo(r, sh - h)
          ..arcToPoint(Offset(h, sh - r), radius: const Radius.circular(r - h))
          ..lineTo(h, sh - arm),
        p);
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.color != color;
}
