import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Pages captured in the current scan (JPEG bytes), plus which page the camera
/// should replace next ([retakeIndex]; null = add a new page).
class ScanSession {
  const ScanSession({this.pages = const [], this.retakeIndex});
  final List<Uint8List> pages;
  final int? retakeIndex;

  bool get isEmpty => pages.isEmpty;

  /// 1-based number of the page the camera is taking now.
  int get currentPageNumber => (retakeIndex ?? pages.length) + 1;
}

class ScanSessionNotifier extends Notifier<ScanSession> {
  @override
  ScanSession build() => const ScanSession();

  void add(Uint8List page) => state = ScanSession(pages: [...state.pages, page]);

  void replace(int index, Uint8List page) {
    if (index < 0 || index >= state.pages.length) return add(page);
    final pages = [...state.pages]..[index] = page;
    state = ScanSession(pages: pages);
  }

  void remove(int index) {
    if (index < 0 || index >= state.pages.length) return;
    state = ScanSession(pages: [...state.pages]..removeAt(index));
  }

  /// The next photo replaces page [index] instead of adding one.
  void retake(int index) => state = ScanSession(pages: state.pages, retakeIndex: index);

  /// The next photo is a new page.
  void addNext() => state = ScanSession(pages: state.pages);

  /// Stores a captured photo: replaces the page being retaken, or appends.
  void capture(Uint8List page) {
    final i = state.retakeIndex;
    if (i == null) {
      add(page);
    } else {
      replace(i, page);
    }
  }

  void clear() => state = const ScanSession();
}

final scanSessionProvider = NotifierProvider<ScanSessionNotifier, ScanSession>(ScanSessionNotifier.new);
