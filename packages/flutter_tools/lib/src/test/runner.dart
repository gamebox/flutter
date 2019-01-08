// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:flutter_tools/src/test/compiler.dart';
import 'package:meta/meta.dart';
import 'package:test_core/src/executable.dart' as test; // ignore: implementation_imports
import 'package:watcher/watcher.dart';

import '../artifacts.dart';
import '../base/common.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../base/process_manager.dart';
import '../base/terminal.dart';
import '../dart/package_map.dart';
import '../globals.dart';
import 'bootstrap.dart';
import 'flutter_platform.dart' as loader;
import 'watcher.dart';

/// Runs tests using package:test and the Flutter engine.
Future<int> runTests(
  List<String> testFiles, {
  Directory workDir,
  List<String> names = const <String>[],
  List<String> plainNames = const <String>[],
  bool enableObservatory = false,
  bool startPaused = false,
  bool ipv6 = false,
  bool machine = false,
  String precompiledDillPath,
  Map<String, String> precompiledDillFiles,
  bool trackWidgetCreation = false,
  bool updateGoldens = false,
  bool watchTests = false,
  TestWatcher watcher,
  @required int concurrency,
}) async {
  // Compute the command-line arguments for package:test.
  final List<String> testArgs = <String>[];
  if (!terminal.supportsColor) {
    testArgs.addAll(<String>['--no-color']);
  }

  if (machine) {
    testArgs.addAll(<String>['-r', 'json']);
  } else {
    testArgs.addAll(<String>['-r', 'compact']);
  }

  testArgs.add('--concurrency=$concurrency');

  for (String name in names) {
    testArgs..add('--name')..add(name);
  }

  for (String plainName in plainNames) {
    testArgs..add('--plain-name')..add(plainName);
  }

  testArgs.add('--');
  testArgs.addAll(testFiles);

  // Configure package:test to use the Flutter engine for child processes.
  final String shellPath = artifacts.getArtifactPath(Artifact.flutterTester);
  if (!processManager.canRun(shellPath))
    throwToolExit('Cannot find Flutter shell at $shellPath');

  final InternetAddressType serverType =
      ipv6 ? InternetAddressType.IPv6 : InternetAddressType.IPv4;

  final Uri projectRootDirectory = fs.currentDirectory.uri;

  final TestCompiler compiler = TestCompiler(trackWidgetCreation, projectRootDirectory);

  final Function compileTestFiles = ({List<String> invalidatedFiles = const <String>[]}) async {
    int index = 0;
    final Map<String, String> precompiledDillFiles = <String, String>{};
    for (String file in testFiles) {
      final String mainDart = createListenerDart(
        ourTestCount: index,
        testPath: file,
        host: loader.kHosts[serverType],
        updateGoldens: updateGoldens,
      );

      final String dillPath = await compiler.compile(mainDart, invalidatedFiles: invalidatedFiles);
      precompiledDillFiles[file] = dillPath;
      index++;
    }

    loader.installHook(
      shellPath: shellPath,
      watcher: watcher,
      enableObservatory: enableObservatory,
      machine: machine,
      startPaused: startPaused,
      serverType: serverType,
      precompiledDillFiles: precompiledDillFiles,
      trackWidgetCreation: trackWidgetCreation,
      updateGoldens: updateGoldens,
      projectRootDirectory: projectRootDirectory,
    );
  };


  await compileTestFiles();

  // Make the global packages path absolute.
  // (Makes sure it still works after we change the current directory.)
  PackageMap.globalPackagesPath =
      fs.path.normalize(fs.path.absolute(PackageMap.globalPackagesPath));

  // Call package:test's main method in the appropriate directory.
  final Directory saved = fs.currentDirectory;
  try {
    if (workDir != null) {
      printTrace('switching to directory $workDir to run tests');
      fs.currentDirectory = workDir;
    }

    await test.main(testArgs);

    if (watchTests) {
      final Completer<void> completer = Completer<void>();
      final DirectoryWatcher directoryWatcher = DirectoryWatcher(saved.path);

      directoryWatcher.events.listen(
        (WatchEvent event) async {
          if (!event.path.endsWith('.dart')) {
            return;
          }
          await compileTestFiles(invalidatedFiles: <String>[event.path]);
          await test.main(testArgs);
        },
        onDone: completer.complete
      );

      await directoryWatcher.ready;

      printStatus('Watcher is ready for events...', emphasis: true, color: TerminalColor.blue);

      await completer.future;
    }

    await compiler.dispose();

    // test.main() sets dart:io's exitCode global.
    printTrace('test package returned with exit code $exitCode');

    return exitCode;
  } finally {
    fs.currentDirectory = saved;
  }
}
