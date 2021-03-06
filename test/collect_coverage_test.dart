// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert' show json, LineSplitter, utf8;
import 'dart:io';

import 'package:coverage/coverage.dart';
import 'package:coverage/src/util.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'test_util.dart';

final _isolateLibPath = p.join('test', 'test_files', 'test_app_isolate.dart');
final _collectAppPath = p.join('bin', 'collect_coverage.dart');

final _sampleAppFileUri = p.toUri(p.absolute(testAppPath)).toString();
final _isolateLibFileUri = p.toUri(p.absolute(_isolateLibPath)).toString();

void main() {
  group('one time collection', () {
    _runTests(false);
  });

  group('on isolate exit', () {
    _runTests(true);
  });
}

void _runTests(bool onExit) {
  test('collect_coverage', () async {
    final resultString = await _getCoverageResult(false);

    // analyze the output json
    final Map<String, dynamic> jsonResult = json.decode(resultString);

    expect(jsonResult.keys, unorderedEquals(<String>['type', 'coverage']));
    expect(jsonResult, containsPair('type', 'CodeCoverage'));

    final List coverage = jsonResult['coverage'];
    expect(coverage, isNotEmpty);

    final sources = coverage.fold<Map<String, dynamic>>(<String, dynamic>{},
        (Map<String, dynamic> map, dynamic value) {
      final String sourceUri = value['source'];
      map.putIfAbsent(sourceUri, () => <Map>[]).add(value);
      return map;
    });

    for (var sampleCoverageData in sources[_sampleAppFileUri]) {
      expect(sampleCoverageData['hits'], isNotNull);
    }

    for (var sampleCoverageData in sources[_isolateLibFileUri]) {
      expect(sampleCoverageData['hits'], isNotEmpty);
    }
  });

  test('createHitmap', () async {
    final resultString = await _getCoverageResult(onExit);
    final Map<String, dynamic> jsonResult = json.decode(resultString);
    final List coverage = jsonResult['coverage'];
    final hitMap = createHitmap(coverage);
    expect(hitMap, contains(_sampleAppFileUri));

    final Map<int, int> isolateFile = hitMap[_isolateLibFileUri];
    final Map<int, int> expectedHits = {
      10: 1,
      11: 1,
      13: 0,
      17: 1,
      18: 1,
      20: 0,
      27: 1,
      29: 1,
      30: 2,
      31: 1,
      32: 3,
      33: 1,
    };
    if (Platform.version.startsWith('1.')) {
      // Dart VMs prior to 2.0.0-dev.5.0 contain a bug that emits coverage on the
      // closing brace of async function blocks.
      // See: https://github.com/dart-lang/coverage/issues/196
      expectedHits[21] = 0;
    } else {
      // Dart VMs version 2.0.0-dev.6.0 mark the opening brace of a function as
      // coverable.
      expectedHits[9] = 1;
      expectedHits[16] = 1;
      expectedHits[26] = 1;
      expectedHits[30] = 3;
    }
    expect(isolateFile, expectedHits);
  });

  test('parseCoverage', () async {
    final tempDir = await Directory.systemTemp.createTemp('coverage.test.');

    try {
      final outputFile = File(p.join(tempDir.path, 'coverage.json'));

      final coverageResults = await _getCoverageResult(onExit);
      await outputFile.writeAsString(coverageResults, flush: true);

      final parsedResult = await parseCoverage([outputFile], 1);

      expect(parsedResult, contains(_sampleAppFileUri));
      expect(parsedResult, contains(_isolateLibFileUri));
    } finally {
      await tempDir.delete(recursive: true);
    }
  });
}

String _coverageData;
String _onExitCoverageData;

Future<String> _getCoverageResult(bool onExit) async {
  if (onExit) {
    return _onExitCoverageData ??= await _collectCoverage(true);
  } else {
    return _coverageData ??= await _collectCoverage(false);
  }
}

Future<String> _collectCoverage(bool onExit) async {
  expect(FileSystemEntity.isFileSync(testAppPath), isTrue);

  final openPort = await getOpenPort();

  // Run the sample app with the right flags.
  final Process sampleProcess = await runTestApp(openPort);

  // Capture the VM service URI.
  final serviceUriCompleter = Completer<Uri>();
  sampleProcess.stdout
      .transform(utf8.decoder)
      .transform(LineSplitter())
      .listen((line) {
    if (!serviceUriCompleter.isCompleted) {
      final Uri serviceUri = extractObservatoryUri(line);
      if (serviceUri != null) {
        serviceUriCompleter.complete(serviceUri);
      }
    }
  });
  final Uri serviceUri = await serviceUriCompleter.future;

  // Run the collection tool.
  // TODO: need to get all of this functionality in the lib
  final params = [
    _collectAppPath,
    '--uri',
    '$serviceUri',
    '--resume-isolates',
  ];
  if (onExit) {
    params.add('--on-exit');
  } else {
    params.add('--wait-paused');
  }

  final toolResult =
      await Process.run('dart', params).timeout(timeout, onTimeout: () {
    throw 'We timed out waiting for the tool to finish.';
  });

  if (toolResult.exitCode != 0) {
    print(toolResult.stdout);
    print(toolResult.stderr);
    fail('Tool failed with exit code ${toolResult.exitCode}.');
  }

  await sampleProcess.exitCode;
  sampleProcess.stderr.drain<List<int>>();

  return toolResult.stdout;
}
