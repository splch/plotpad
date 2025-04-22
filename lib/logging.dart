import 'package:logging/logging.dart';

/// Call this once at app startup (before anything else logs).
void initLogging() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    // customize this however you like
    print(
      '${record.time.toIso8601String()} '
      '[${record.level.name}] '
      '${record.loggerName}: '
      '${record.message}',
    );
  });
}
