import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:logging/logging.dart';

import 'logging.dart';
import 'models/sheet.dart';
import 'providers.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1) start logging
  initLogging();
  final log = Logger('main');
  log.info('🔄 Starting PlotPad…');

  // 2) open your DB
  final dir = await getApplicationDocumentsDirectory();
  log.fine('Got documents directory: ${dir.path}');
  final isar = Isar.open(schemas: [SheetSchema], directory: dir.path);
  log.info('Isar opened');

  // 3) run app
  runApp(
    ProviderScope(
      overrides: [isarProvider.overrideWithValue(isar)],
      child: const MainApp(),
    ),
  );
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});
  @override
  Widget build(BuildContext context) {
    Logger('MainApp').info('Building MainApp widget');
    return MaterialApp(
      title: 'PlotPad',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const HomeScreen(),
    );
  }
}
