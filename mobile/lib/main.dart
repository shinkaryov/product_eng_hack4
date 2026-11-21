import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'data/local_prefs.dart';
import 'data/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await LocalPrefs.load();
  runApp(ProviderScope(
    overrides: [localPrefsProvider.overrideWithValue(prefs)],
    child: const FamilyDocApp(),
  ));
}
