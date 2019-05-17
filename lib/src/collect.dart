// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:vm_service_client/vm_service_client.dart';
import 'util.dart';

const _retryInterval = Duration(milliseconds: 200);

/// Collects coverage for all isolates in the running VM.
///
/// Collects a hit-map containing merged coverage for all isolates in the Dart
/// VM associated with the specified [serviceUri]. Returns a map suitable for
/// input to the coverage formatters that ship with this package.
///
/// [serviceUri] must specify the http/https URI of the service port of a
/// running Dart VM and must not be null.
///
/// If [resume] is true, all isolates will be resumed once coverage collection
/// is complete.
///
/// If [waitPaused] is true, collection will not begin until all isolates are
/// in the paused state.
Future<Map<String, dynamic>> collect(
    Uri serviceUri, bool resume, bool waitPaused, bool onExit,
    {Duration timeout}) async {
  _CoverageCollector collector;
  if (onExit) {
    collector = _OnExitCollector(serviceUri, resume, timeout: timeout);
  } else {
    collector =
        _OneTimeCollector(serviceUri, waitPaused, resume, timeout: timeout);
  }

  return await collector.collect();
}

abstract class _CoverageCollector {
  _CoverageCollector(this.serviceUri, {this.timeout}) {
    if (serviceUri == null) throw ArgumentError('serviceUri must not be null');
  }

  final List<Map<String, dynamic>> _collectedCoverage = [];

  final Duration timeout;
  final Uri serviceUri;

  VMServiceClient vmService;

  Future<VMServiceClient> connectToVMService() async {
    // Create websocket URI. Handle any trailing slashes.
    final pathSegments =
        serviceUri.pathSegments.where((c) => c.isNotEmpty).toList()..add('ws');
    final uri = serviceUri.replace(scheme: 'ws', pathSegments: pathSegments);

    return await retry(() async {
      try {
        final vmService = VMServiceClient.connect(uri);
        await vmService.getVM().timeout(_retryInterval);
        return vmService;
      } on TimeoutException {
        vmService.close();
        rethrow;
      }
    }, _retryInterval, timeout: timeout);
  }

  Future prepare();
  Future collectCoverage();
  Future tearDown();

  Future<Map<String, dynamic>> collect() async {
    vmService = await connectToVMService();

    try {
      await prepare();
      await collectCoverage();
    } finally {
      await tearDown();
      await vmService.close();
    }

    return <String, dynamic>{
      'type': 'CodeCoverage',
      'coverage': _collectedCoverage,
    };
  }

  Future<void> collectFromIsolate(VMIsolateRef isolateRef) async {
    final isolate = await isolateRef.load();
    final report = await isolate.getSourceReport(forceCompile: true);
    final coverage = await _getCoverageJson(vmService, report);

    _collectedCoverage.addAll(coverage);
  }
}

/// Collects coverage once, optionally waiting until all isolates have paused
/// and optionally resuming them afterwards.
class _OneTimeCollector extends _CoverageCollector {
  _OneTimeCollector(Uri serviceUri, this.waitPaused, this.resume,
      {Duration timeout})
      : super(serviceUri, timeout: timeout);

  final bool waitPaused;
  final bool resume;

  @override
  Future prepare() {
    if (waitPaused) {
      Future<void> allPaused() async {
        final vm = await vmService.getVM();
        for (var isolateRef in vm.isolates) {
          final isolate = await isolateRef.load();
          if (!isolate.isPaused) throw "Unpaused isolates remaining.";
        }
      }

      return retry<void>(allPaused, _retryInterval, timeout: timeout);
    }

    return Future<void>.value(null);
  }

  @override
  Future collectCoverage() async {
    final vm = await vmService.getVM();

    for (var isolateRef in vm.isolates) {
      await collectFromIsolate(isolateRef);
    }
  }

  @override
  Future tearDown() async {
    if (resume) {
      final vm = await vmService.getVM();
      for (var isolateRef in vm.isolates) {
        final isolate = await isolateRef.load();
        if (isolate.isPaused) {
          await isolateRef.resume();
        }
      }
    }
  }
}

/// Collects coverage when isolates pause before exiting, optionally resuming
/// them afterwards.
class _OnExitCollector extends _CoverageCollector {
  _OnExitCollector(Uri serviceUri, this.resume, {Duration timeout})
      : super(serviceUri, timeout: timeout);

  final bool resume;
  final Completer<void> _allIsolatesExited = Completer();

  Map<VMIsolateRef, StreamSubscription> _exitSubscriptions = {};
  StreamSubscription _isolateStartSubscription;

  Completer<void> _currentCollection;

  @override
  Future prepare() async {}

  @override
  Future collectCoverage() async {
    // Track all active isolates, also track isolates when they are started
    final vm = await vmService.getVM();
    var allIsolatesAlreadyPaused = true;

    // Collection could have started at a time in which all isolates have
    // already been paused before exiting. In that case, waiting for new
    // isolates to start will take forever.
    for (var isolateRef in vm.isolates) {
      final isolatePaused = await _trackIsolate(isolateRef);
      if (!isolatePaused) {
        allIsolatesAlreadyPaused = false;
      }
    }

    if (!allIsolatesAlreadyPaused) {
      _isolateStartSubscription =
          vmService.onIsolateStart.listen(_trackIsolate);

      await _allIsolatesExited.future;
      await _isolateStartSubscription.cancel();
    }
  }

  // Tracks the isolate to collect coverage when it exists. Returns true if the
  // isolate is already exiting.
  Future<bool> _trackIsolate(VMIsolateRef isolate) async {
    // check if the isolate is already paused
    final isolateData = await isolate.load();
    if (isolateData.pauseEvent is VMPauseExitEvent) {
      await _collectAndResume(isolate);
      return true;
    } else {
      // collect coverage when the isolate is about to exit
      _exitSubscriptions[isolate] = isolate.onPauseOrResume
          .where((event) => event is VMPauseExitEvent)
          .listen((_) {
        _collectFromExitingIsolate(isolate);
      });
      return false;
    }
  }

  Future _collectFromExitingIsolate(VMIsolateRef isolate) async {
    await _collectAndResume(isolate, cancelSubscription: true);

    if (_exitSubscriptions.isEmpty && !_allIsolatesExited.isCompleted) {
      _allIsolatesExited.complete(null);
    }
  }

  Future<void> _collectAndResume(VMIsolateRef isolate,
      {bool cancelSubscription = false}) async {
    // only collect from one isolate at a time
    while (_currentCollection != null && !_currentCollection.isCompleted) {
      await _currentCollection.future;
    }

    _currentCollection = Completer<void>();
    await collectFromIsolate(isolate);
    if (resume) {
      await isolate.resume();
    }

    if (cancelSubscription) {
      await _exitSubscriptions.remove(isolate).cancel();
    }

    _currentCollection.complete();
  }

  @override
  Future tearDown() async {}
}

/// Returns a JSON coverage list backward-compatible with pre-1.16.0 SDKs.
Future<List<Map<String, dynamic>>> _getCoverageJson(
    VMServiceClient service, VMSourceReport report) async {
  final scriptRefs = report.ranges.map((r) => r.script).toSet();
  final scripts = <VMScriptRef, VMScript>{};
  for (var ref in scriptRefs) {
    scripts[ref] = await ref.load();
  }

  // script uri -> { line -> hit count }
  final hitMaps = <Uri, Map<int, int>>{};
  for (var range in report.ranges) {
    // Not returned in scripts section of source report.
    if (range.script.uri.scheme == 'evaluate') continue;

    hitMaps.putIfAbsent(range.script.uri, () => <int, int>{});
    final hitMap = hitMaps[range.script.uri];
    final script = scripts[range.script];
    for (VMScriptToken hit in range.hits ?? []) {
      final line = script.sourceLocation(hit).line + 1;
      hitMap[line] = hitMap.containsKey(line) ? hitMap[line] + 1 : 1;
    }
    for (VMScriptToken miss in range.misses ?? []) {
      final line = script.sourceLocation(miss).line + 1;
      hitMap.putIfAbsent(line, () => 0);
    }
  }

  // Output JSON
  final coverage = <Map<String, dynamic>>[];
  hitMaps.forEach((uri, hitMap) {
    coverage.add(_toScriptCoverageJson(uri, hitMap));
  });
  return coverage;
}

/// Returns a JSON hit map backward-compatible with pre-1.16.0 SDKs.
Map<String, dynamic> _toScriptCoverageJson(
    Uri scriptUri, Map<int, int> hitMap) {
  final json = <String, dynamic>{};
  final hits = <int>[];
  hitMap.forEach((line, hitCount) {
    hits.add(line);
    hits.add(hitCount);
  });
  json['source'] = '$scriptUri';
  json['script'] = {
    'type': '@Script',
    'fixedId': true,
    'id': 'libraries/1/scripts/${Uri.encodeComponent(scriptUri.toString())}',
    'uri': '$scriptUri',
    '_kind': 'library',
  };
  json['hits'] = hits;
  return json;
}
