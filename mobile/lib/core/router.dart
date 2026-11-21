import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/models.dart';
import '../data/providers.dart';
import '../features/add/processing_screen.dart';
import '../features/add/scan_review_screen.dart';
import '../features/add/scan_screen.dart';
import '../features/ask/ask_screen.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/auth/sign_up_screen.dart';
import '../features/auth/splash_screen.dart';
import '../features/deadlines/deadlines_screen.dart';
import '../features/document/blocked_screen.dart';
import '../features/document/deadline_confirm_screen.dart';
import '../features/document/document_screen.dart';
import '../features/document/review_screen.dart';
import '../features/home/home_screen.dart';
import '../features/household/household_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/vault/vault_screen.dart';
import '../ui/shell/app_shell.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Route paths. Keep all navigation going through these.
abstract final class Routes {
  static const splash = '/splash';
  static const signIn = '/sign-in';
  static const signUp = '/sign-up';
  static const home = '/home';
  static const vault = '/vault';
  static const deadlines = '/deadlines';
  static const ask = '/ask';
  static const household = '/household';
  static const settings = '/settings';
  static const scan = '/scan';
  static const scanReview = '/scan/review';

  /// Document (Details / File / Deadlines / Sharing); FAILED shows the failed state. Lives in the Vault tab.
  static String document(String id) => '/vault/doc/$id';
  static String review(String id) => '/review/$id';
  static String confirmDeadline(String id) => '/deadline/$id';
  static String processing(String id) => '/processing/$id';
  static String blocked(String id) => '/blocked/$id';

  /// Ask, optionally pre-filled with a question.
  static String askWith(String q) => Uri(path: ask, queryParameters: {'q': q}).toString();
}

/// Opens the right screen for a document's state.
void openDocument(BuildContext context, Document d) {
  switch (d.reviewStatus) {
    case ReviewStatus.uploaded || ReviewStatus.processing:
      context.push(Routes.processing(d.id));
    case ReviewStatus.reviewRequired:
      context.push(Routes.review(d.id));
    case ReviewStatus.blocked:
      context.push(Routes.blocked(d.id));
    default:
      if (d.isWorking) {
        context.push(Routes.processing(d.id));
      } else {
        context.go(Routes.document(d.id));
      }
  }
}

/// Bridges the Riverpod session to go_router's refreshListenable.
class _SessionListenable extends ChangeNotifier {
  _SessionListenable(Ref ref) {
    ref.listen(sessionProvider, (prev, next) {
      if (prev.runtimeType != next.runtimeType) notifyListeners();
    });
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final listenable = _SessionListenable(ref);
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: Routes.splash,
    refreshListenable: listenable,
    redirect: (context, state) {
      final s = ref.read(sessionProvider);
      final loc = state.matchedLocation;
      final isAuth = loc == Routes.signIn || loc == Routes.signUp;
      if (s is SessionLoading) return loc == Routes.splash ? null : Routes.splash;
      if (s is SignedOut) return isAuth ? null : Routes.signIn;
      if (isAuth || loc == Routes.splash) return Routes.home;
      return null;
    },
    routes: [
      GoRoute(path: Routes.splash, builder: (_, __) => const SplashScreen()),
      GoRoute(path: Routes.signIn, builder: (_, __) => const SignInScreen()),
      GoRoute(path: Routes.signUp, builder: (_, __) => const SignUpScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(navigationShell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: Routes.home, builder: (_, __) => const HomeScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: Routes.vault, builder: (_, __) => const VaultScreen(), routes: [
              GoRoute(path: 'doc/:id', builder: (_, s) => DocumentScreen(id: s.pathParameters['id']!)),
            ]),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: Routes.deadlines, builder: (_, __) => const DeadlinesScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: Routes.ask, builder: (_, s) => AskScreen(initialQuestion: s.uri.queryParameters['q'])),
          ]),
        ],
      ),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: Routes.household, builder: (_, __) => const HouseholdScreen()),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: Routes.settings, builder: (_, __) => const SettingsScreen()),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: Routes.scan, builder: (_, __) => const ScanScreen()),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: Routes.scanReview, builder: (_, __) => const ScanReviewScreen()),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: '/review/:id', builder: (_, s) => ReviewScreen(id: s.pathParameters['id']!)),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: '/deadline/:id', builder: (_, s) => DeadlineConfirmScreen(documentId: s.pathParameters['id']!)),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: '/processing/:id', builder: (_, s) => ProcessingScreen(id: s.pathParameters['id']!)),
      GoRoute(parentNavigatorKey: rootNavigatorKey, path: '/blocked/:id', builder: (_, s) => BlockedScreen(id: s.pathParameters['id']!)),
    ],
  );
});
