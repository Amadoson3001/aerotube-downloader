import 'package:flutter_driver/flutter_driver.dart' as driver;
import 'package:integration_test/integration_test_driver.dart';

/// Performance tracing driver for `flutter drive --profile`.
///
/// Usage:
///   flutter drive \
///     --driver=test_driver/perf_driver.dart \
///     --target=integration_test/perf_tracing_test.dart \
///     --profile
///
/// Summarizes every timeline recorded via `binding.traceAction(..., reportKey: ...)`
/// and writes `<reportKey>.timeline.json` + `<reportKey>.timeline_summary.json`
/// into `build/`.
Future<void> main() {
  return integrationDriver(
    responseDataCallback: (data) async {
      if (data == null) return;
      for (final entry in data.entries) {
        final value = entry.value;
        if (value is Map<String, dynamic> && value.containsKey('traceEvents')) {
          final timeline = driver.Timeline.fromJson(value);
          final summary = driver.TimelineSummary.summarize(timeline);
          await summary.writeTimelineToFile(
            entry.key,
            pretty: true,
            includeSummary: true,
          );
        }
      }
    },
  );
}
