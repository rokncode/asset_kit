import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../config.dart';
import '../errors.dart';
import '../logger.dart';
import '../scale.dart';
import 'build_cache.dart';
import 'cwebp.dart';
import 'dart_encoder.dart';
import 'image_probe.dart';
import 'svg_optimizer.dart';

/// Bump when the processing pipeline changes in a way that should
/// invalidate every cached output.
const _pipelineVersion = 1;

enum SourceKind { raster, svg, font, copy }

const _rasterExtensions = {'.png', '.jpg', '.jpeg', '.webp'};
const _fontExtensions = {'.ttf', '.otf'};

SourceKind sourceKindOf(String path) {
  final ext = p.extension(path).toLowerCase();
  if (_rasterExtensions.contains(ext)) return SourceKind.raster;
  if (ext == '.svg') return SourceKind.svg;
  if (_fontExtensions.contains(ext)) return SourceKind.font;
  return SourceKind.copy;
}

/// The extension a raster source is written with.
///
/// `webp` needs cwebp. Without it, PNG and WebP sources fall back to
/// optimized PNG, while JPEG sources stay JPEG: a photo re-encoded as
/// lossless PNG would grow several times over. `keep` preserves the source
/// format, except WebP sources without cwebp, which become PNG.
String outputExtension(String sourceExt, ImageFormat format, {required bool cwebpAvailable}) {
  final ext = sourceExt.toLowerCase();
  final isJpeg = ext == '.jpg' || ext == '.jpeg';
  return switch (format) {
    ImageFormat.webp when cwebpAvailable => '.webp',
    ImageFormat.webp => isJpeg ? ext : '.png',
    ImageFormat.png => '.png',
    ImageFormat.keep => ext == '.webp' && !cwebpAvailable ? '.png' : ext,
  };
}

/// Everything needed to produce the outputs of one source file.
class _Plan {
  _Plan(this.source, this.absPath, this.kind, this.bytes);

  /// POSIX path relative to the source folder.
  final String source;
  final String absPath;
  final SourceKind kind;
  final Uint8List bytes;

  late final String hash = sha256.convert(bytes).toString();
  late String settings;

  /// Project-relative POSIX path of the 1x / main output.
  late String mainOutput;

  /// Raster only.
  ImageProbe? probe;
  double sourceScale = 1;
  List<VariantSize> variants = const [];
  List<double> skippedScales = const [];
  bool lossless = false;
  String outputExt = '';

  /// Project-relative POSIX paths of every output.
  List<String> get outputs => kind == SourceKind.raster
      ? [for (final v in variants) variantPath(mainOutput, v.scale)]
      : [mainOutput, ?vecOutput];

  /// SVG precompile output, if enabled.
  String? vecOutput;
}

enum FileStatus { processed, cached, planned, failed }

/// Outcome for one source file.
class FileReport {
  FileReport({
    required this.source,
    required this.kind,
    required this.status,
    this.sourceSize = 0,
    this.outputSize = 0,
    this.outputs = const [],
    this.skippedScales = const [],
    this.error,
  });

  final String source;
  final SourceKind kind;
  final FileStatus status;
  final int sourceSize;

  /// Total size of all outputs (every scale variant).
  final int outputSize;
  final List<String> outputs;
  final List<double> skippedScales;
  final String? error;
}

class OptimizeReport {
  OptimizeReport({required this.files, required this.removedStale, required this.encoder});

  final List<FileReport> files;

  /// Outputs deleted because their source was removed or renamed.
  final List<String> removedStale;

  /// Human-readable encoder description, e.g. `cwebp 1.6.0`.
  final String encoder;

  bool get hasErrors => files.any((f) => f.status == FileStatus.failed);
  Iterable<FileReport> get processed => files.where((f) => f.status == FileStatus.processed);
  Iterable<FileReport> get cached => files.where((f) => f.status == FileStatus.cached);
}

class OptimizeOptions {
  const OptimizeOptions({this.dryRun = false, this.force = false, this.jobs, this.precompileSvg});

  final bool dryRun;

  /// Ignore the cache and reprocess everything.
  final bool force;

  /// Parallel jobs; defaults to the number of processors.
  final int? jobs;

  /// Overrides `svg.precompile` when non-null.
  final bool? precompileSvg;
}

/// Turns the source folder into Flutter's resolution-aware output folder.
class Optimizer {
  Optimizer(this.config, this.logger, {this.options = const OptimizeOptions(), this.cwebp});

  final AssetKitConfig config;
  final Logger logger;
  final OptimizeOptions options;

  /// The located cwebp, or null to use the PNG fallback.
  final Cwebp? cwebp;

  late final String _outputRoot = p.posix.joinAll(
    p.split(p.relative(config.outputDir, from: config.projectRoot)),
  );

  /// Whether SVGs are precompiled in this run: requested, and possible.
  bool _precompile = false;

  Future<OptimizeReport> run() async {
    if (!Directory(config.sourceDir).existsSync()) {
      throw AssetKitException(
        'Source folder "${config.source}" does not exist.',
        hint: 'Run `asset_kit init`, or set `source` in $defaultConfigFileName.',
      );
    }

    final sources = _scanSources().toList();

    // Decide before planning, so the cache fingerprint records whether
    // precompilation really happened.
    _precompile = options.precompileSvg ?? config.svg.precompile;
    if (_precompile &&
        sources.any((s) => sourceKindOf(s.$1) == SourceKind.svg) &&
        !_hasVectorGraphicsCompiler()) {
      logger
        ..warn(
          'svg.precompile is on, but vector_graphics_compiler is not a dependency of this project. '
          'Skipping precompilation.',
        )
        ..hint('flutter pub add dev:vector_graphics_compiler');
      _precompile = false;
    }

    final reports = <FileReport>[];
    final plans = <_Plan>[];
    for (final (source, abs) in sources) {
      try {
        plans.add(_plan(source, abs));
      } on _PlanError catch (e) {
        reports.add(
          FileReport(
            source: source,
            kind: sourceKindOf(source),
            status: FileStatus.failed,
            error: e.message,
          ),
        );
      }
    }
    _rejectConflicts(plans, reports);

    final cache = BuildCache.load(p.join(config.cacheDir, 'cache.json'));
    final pending = <_Plan>[];
    for (final plan in plans) {
      final fresh =
          !options.force &&
          cache.isFresh(
            plan.source,
            hash: plan.hash,
            settings: plan.settings,
            projectRoot: config.projectRoot,
          );
      if (fresh) {
        final entry = cache.entries[plan.source]!;
        reports.add(
          FileReport(
            source: plan.source,
            kind: plan.kind,
            status: FileStatus.cached,
            sourceSize: entry.sourceSize,
            outputSize: entry.outputSize,
            outputs: entry.outputs,
            skippedScales: plan.skippedScales,
          ),
        );
        logger.detail('cached   ${plan.source}');
      } else {
        pending.add(plan);
      }
    }

    if (options.dryRun) {
      for (final plan in pending) {
        reports.add(
          FileReport(
            source: plan.source,
            kind: plan.kind,
            status: FileStatus.planned,
            sourceSize: plan.bytes.length,
            outputs: plan.outputs,
            skippedScales: plan.skippedScales,
          ),
        );
      }
    } else {
      reports.addAll(await _execute(pending));
    }

    final removed = <String>[];
    if (!options.dryRun) {
      removed.addAll(_updateCache(cache, plans, reports));
    } else {
      final failed = {
        for (final r in reports)
          if (r.status == FileStatus.failed) r.source,
      };
      removed.addAll(_staleOutputs(cache, plans, failed));
    }

    reports.sort((a, b) => a.source.compareTo(b.source));
    return OptimizeReport(
      files: reports,
      removedStale: removed,
      encoder: cwebp != null ? 'cwebp ${cwebp!.version}' : 'built-in PNG encoder',
    );
  }

  /// Lists source files as (path relative to source folder, absolute path).
  Iterable<(String, String)> _scanSources() sync* {
    final entities = Directory(config.sourceDir).listSync(recursive: true, followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entities) {
      if (entity is! File) continue;
      final segments = p.split(p.relative(entity.path, from: config.sourceDir));
      if (segments.any((s) => s.startsWith('.'))) continue;
      if (entity.path.endsWith('.asset_kit.tmp')) continue;
      final dirs = segments.take(segments.length - 1);
      if (dirs.any(variantDirPattern.hasMatch)) {
        logger.warn(
          '${segments.join('/')} is inside a scale folder in ${config.source}/. '
          'Put only originals there (use an @3x suffix or folder_scales). Skipped.',
        );
        continue;
      }
      yield (segments.join('/'), entity.path);
    }
  }

  _Plan _plan(String source, String abs) {
    final plan = _Plan(source, abs, sourceKindOf(source), File(abs).readAsBytesSync());
    final dir = p.posix.dirname(source);
    String outPath(String fileName) => p.posix.normalize(p.posix.join(_outputRoot, dir, fileName));

    switch (plan.kind) {
      case SourceKind.raster:
        final parsed = parseScaleSuffix(p.posix.basename(source));
        plan.sourceScale = parsed.scale ?? config.sourceScaleFor(source);
        final probe = plan.probe = probeImage(plan.bytes);
        if (probe == null) throw _PlanError('Not a readable PNG, JPEG or WebP image.');
        plan.outputExt = outputExtension(
          p.extension(source),
          config.images.format,
          cwebpAvailable: cwebp != null,
        );
        plan.lossless = config.images.isLossless(source);
        final variantPlan = planVariants(
          width: probe.width,
          height: probe.height,
          sourceScale: plan.sourceScale,
          scales: config.scales,
        );
        plan
          ..variants = variantPlan.variants
          ..skippedScales = variantPlan.skipped
          ..mainOutput = outPath('${p.withoutExtension(parsed.name)}${plan.outputExt}')
          ..settings = [
            'v$_pipelineVersion',
            'raster',
            plan.outputExt == '.webp' ? 'cwebp ${cwebp!.version}' : 'dart',
            'ext=${plan.outputExt}',
            // Quality only matters for lossy encodes.
            if (plan.outputExt != '.png' && !plan.lossless) 'q=${config.images.quality}',
            'lossless=${plan.lossless}',
            'src=${plan.sourceScale}',
            'scales=${config.scales.join(',')}',
          ].join('|');
      case SourceKind.svg:
        plan
          ..mainOutput = outPath(p.posix.basename(source))
          ..vecOutput = _precompile
              ? outPath('${p.posix.basenameWithoutExtension(source)}.vec')
              : null
          ..settings =
              'v$_pipelineVersion|svg|optimize=${config.svg.optimize}|precompile=$_precompile';
      case SourceKind.font:
      case SourceKind.copy:
        plan
          ..mainOutput = outPath(p.posix.basename(source))
          ..settings = 'v$_pipelineVersion|copy';
    }
    return plan;
  }

  /// Two sources that would write the same output (`logo.png` and
  /// `logo.jpg`, or `logo.png` and `logo@3x.png`) both fail.
  void _rejectConflicts(List<_Plan> plans, List<FileReport> reports) {
    final byOutput = <String, List<_Plan>>{};
    for (final plan in plans) {
      for (final output in plan.outputs.take(1)) {
        (byOutput[output] ??= []).add(plan);
      }
    }
    for (final MapEntry(key: output, value: group) in byOutput.entries) {
      if (group.length < 2) continue;
      for (final plan in group) {
        plans.remove(plan);
        final others = group.where((o) => o != plan).map((o) => o.source).join(', ');
        reports.add(
          FileReport(
            source: plan.source,
            kind: plan.kind,
            status: FileStatus.failed,
            error: 'Writes the same output ($output) as $others. Rename one of them.',
          ),
        );
      }
    }
  }

  Future<List<FileReport>> _execute(List<_Plan> pending) async {
    final results = <FileReport>[];
    var done = 0;
    await _forEachConcurrent(pending, options.jobs ?? Platform.numberOfProcessors, (plan) async {
      FileReport report;
      try {
        await _process(plan);
        final outputs = plan.outputs;
        final size = outputs.fold<int>(
          0,
          (sum, o) => sum + File(p.join(config.projectRoot, o)).lengthSync(),
        );
        report = FileReport(
          source: plan.source,
          kind: plan.kind,
          status: FileStatus.processed,
          sourceSize: plan.bytes.length,
          outputSize: size,
          outputs: outputs,
          skippedScales: plan.skippedScales,
        );
      } on Object catch (e) {
        report = FileReport(
          source: plan.source,
          kind: plan.kind,
          status: FileStatus.failed,
          error: e is AssetKitException ? e.message : '$e',
        );
      }
      results.add(report);
      done++;
      _printProgress(done, pending.length, report);
    });
    return results;
  }

  void _printProgress(int done, int total, FileReport r) {
    if (r.status == FileStatus.failed) {
      logger.progress(done, total, '${logger.red('✗')} ${r.source}: ${r.error}');
      return;
    }
    final scales = r.kind == SourceKind.raster
        ? ' ${logger.dim('(${r.outputs.length} variant${r.outputs.length == 1 ? '' : 's'})')}'
        : '';
    final target = r.outputs.isEmpty ? '' : ' → ${p.posix.basename(r.outputs.first)}';
    logger.progress(done, total, '${r.source}$target$scales');
    if (r.skippedScales.isNotEmpty) {
      logger.warn(
        '${r.source}: source is too small for '
        '${r.skippedScales.map(variantDirName).join(', ')} (never upscaling). '
        'Export it at a higher resolution or lower its source scale.',
      );
    }
  }

  Future<void> _process(_Plan plan) async {
    String abs(String rel) => p.join(config.projectRoot, rel);
    switch (plan.kind) {
      case SourceKind.raster:
        await _processRaster(plan, abs);
      case SourceKind.svg:
        final output = config.svg.optimize ? _optimizeSvg(plan) : plan.bytes;
        writeAtomically(abs(plan.mainOutput), output);
        if (plan.vecOutput case final vec?) {
          await _precompileSvg(abs(plan.mainOutput), abs(vec));
        }
      case SourceKind.font:
      case SourceKind.copy:
        writeAtomically(abs(plan.mainOutput), plan.bytes);
    }
  }

  Future<void> _processRaster(_Plan plan, String Function(String) abs) async {
    final probe = plan.probe!;
    final variants = [
      for (final v in plan.variants)
        (path: abs(variantPath(plan.mainOutput, v.scale)), width: v.width, height: v.height),
    ];

    if (plan.outputExt == '.webp') {
      var input = plan.absPath;
      Directory? tmpDir;
      if (probe.needsRotation) {
        // cwebp ignores EXIF orientation: rotate in Dart first.
        tmpDir = Directory.systemTemp.createTempSync('asset_kit');
        input = p.join(tmpDir.path, 'rotated.png');
        await encodeWithDart(
          sourcePath: plan.absPath,
          variants: [(path: input, width: probe.width, height: probe.height)],
          encoding: DartEncoding.pngIntermediate,
        );
      }
      try {
        for (final v in variants) {
          final resize = v.width != probe.width || v.height != probe.height;
          final tmp = '${v.path}.asset_kit.tmp';
          File(tmp).parent.createSync(recursive: true);
          await cwebp!.encode(
            input: input,
            output: tmp,
            quality: config.images.quality,
            lossless: plan.lossless,
            width: resize ? v.width : null,
            height: resize ? v.height : null,
          );
          File(tmp).renameSync(v.path);
        }
      } finally {
        tmpDir?.deleteSync(recursive: true);
      }
    } else {
      await encodeWithDart(
        sourcePath: plan.absPath,
        variants: variants,
        encoding: plan.outputExt == '.png' ? DartEncoding.png : DartEncoding.jpg,
        quality: config.images.quality,
      );
    }

    // Never ship a re-encode that is larger than an untouched original of
    // the same format and size.
    final sameFormat = p.extension(plan.source).toLowerCase() == plan.outputExt;
    for (final v in variants) {
      if (sameFormat &&
          !probe.needsRotation &&
          v.width == probe.width &&
          v.height == probe.height) {
        final out = File(v.path);
        if (out.lengthSync() >= plan.bytes.length) writeAtomically(v.path, plan.bytes);
      }
    }
  }

  List<int> _optimizeSvg(_Plan plan) {
    final text = utf8.decode(plan.bytes, allowMalformed: true);
    try {
      final optimized = utf8.encode(optimizeSvg(text).output);
      return optimized.length < plan.bytes.length ? optimized : plan.bytes;
    } on XmlException catch (e) {
      logger.warn('${plan.source}: not valid XML (${e.message}); copied without optimizing.');
      return plan.bytes;
    }
  }

  bool _hasVectorGraphicsCompiler() {
    final file = File(p.join(config.projectRoot, '.dart_tool', 'package_config.json'));
    return file.existsSync() && file.readAsStringSync().contains('"vector_graphics_compiler"');
  }

  Future<void> _precompileSvg(String svgPath, String vecPath) async {
    final result = await Process.run(
      'dart',
      ['run', 'vector_graphics_compiler', '-i', svgPath, '-o', vecPath],
      workingDirectory: config.projectRoot,
      runInShell: Platform.isWindows,
    );
    if (result.exitCode != 0) {
      throw AssetKitException('vector_graphics_compiler failed: ${'${result.stderr}'.trim()}');
    }
  }

  /// Outputs recorded in the cache that no current source produces.
  /// Outputs of sources that failed this run are kept.
  List<String> _staleOutputs(BuildCache cache, List<_Plan> plans, Set<String> failedSources) {
    final keep = {
      for (final plan in plans) ...plan.outputs,
      for (final source in failedSources) ...?cache.entries[source]?.outputs,
    };
    return {
      for (final entry in cache.entries.values)
        for (final output in entry.outputs)
          if (!keep.contains(output) && File(p.join(config.projectRoot, output)).existsSync())
            output,
    }.toList()..sort();
  }

  /// Records successful results, deletes stale outputs and saves the cache.
  List<String> _updateCache(BuildCache cache, List<_Plan> plans, List<FileReport> reports) {
    final failed = {
      for (final r in reports)
        if (r.status == FileStatus.failed) r.source,
    };
    final stale = _staleOutputs(cache, plans, failed);
    for (final output in stale) {
      final file = File(p.join(config.projectRoot, output));
      file.deleteSync();
      _removeEmptyParents(file.parent);
    }

    final planBySource = {for (final plan in plans) plan.source: plan};
    final updated = <String, CacheEntry>{};
    for (final report in reports) {
      final previous = cache.entries[report.source];
      final plan = planBySource[report.source];
      if (report.status == FileStatus.processed && plan != null) {
        updated[report.source] = CacheEntry(
          sourceHash: plan.hash,
          settings: plan.settings,
          outputs: report.outputs,
          sourceSize: report.sourceSize,
          outputSize: report.outputSize,
        );
      } else if (previous != null && report.status != FileStatus.processed) {
        // Cached, or failed this time: keep the old record so its outputs
        // stay tracked.
        updated[report.source] = previous;
      }
    }
    cache.entries
      ..clear()
      ..addAll(updated);
    cache.save();
    return stale;
  }

  /// Deletes now-empty folders up to (not including) the output folder.
  void _removeEmptyParents(Directory dir) {
    final root = p.normalize(config.outputDir);
    var current = dir;
    while (p.isWithin(root, current.path) && current.existsSync() && current.listSync().isEmpty) {
      current.deleteSync();
      current = current.parent;
    }
  }
}

class _PlanError implements Exception {
  _PlanError(this.message);
  final String message;
}

/// Runs [action] for every item with at most [concurrency] in flight.
Future<void> _forEachConcurrent<T>(
  List<T> items,
  int concurrency,
  Future<void> Function(T) action,
) async {
  var next = 0;
  Future<void> worker() async {
    while (next < items.length) {
      final item = items[next++];
      await action(item);
    }
  }

  await Future.wait([
    for (var i = 0; i < concurrency.clamp(1, items.isEmpty ? 1 : items.length); i++) worker(),
  ]);
}
