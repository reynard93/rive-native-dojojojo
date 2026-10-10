import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

const androidNdkVersion = '27.2.12479018';
const androidBuildConfiguration = 'release android flutter-runtime';

class AndroidNativeCache {
  static const manifestName = '.rive-native-cache.json';
  static const _abis = {
    'armeabi-v7a': (elfClass: 1, machine: 40),
    'arm64-v8a': (elfClass: 2, machine: 183),
    'x86': (elfClass: 1, machine: 3),
    'x86_64': (elfClass: 2, machine: 62),
  };

  final Directory directory;
  final String revision;

  AndroidNativeCache(Directory directory, this.revision)
    : directory = directory.absolute;

  static Future<AndroidNativeCache> forPackage(String packagePath) async {
    final result = await Process.run('git', [
      'rev-parse',
      '--verify',
      'HEAD^{commit}',
    ], workingDirectory: packagePath);
    if (result.exitCode != 0) {
      throw Exception(
        'Unable to resolve rive_native Git HEAD: ${result.stderr}',
      );
    }
    final revision = result.stdout.toString().trim();
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(revision)) {
      throw Exception('Invalid rive_native Git HEAD: $revision');
    }
    return AndroidNativeCache(
      Directory('$packagePath/android/src/main/jniLibs'),
      revision,
    );
  }

  String get key =>
      '$revision-ndk-$androidNdkVersion-'
      '${androidBuildConfiguration.replaceAll(' ', '-')}-${Abi.current()}';

  File get manifest => File('${directory.path}/$manifestName');

  Map<String, Object> get _identity => {
    'schemaVersion': 1,
    'key': key,
    'revision': revision,
    'ndkVersion': androidNdkVersion,
    'configuration': androidBuildConfiguration,
  };

  Map<String, Object> get info => {
    'key': key,
    'path': directory.path,
    'revision': revision,
    'ndkVersion': androidNdkVersion,
    'configuration': androidBuildConfiguration,
  };

  /// Returns a cache-miss reason; filesystem and checksum-tool failures escape.
  Future<String?> invalidReason({bool clean = false}) async {
    if (clean) return '--clean requested';
    if (!await manifest.exists()) return 'manifest missing';

    Object? decoded;
    try {
      decoded = jsonDecode(await manifest.readAsString());
    } on FormatException {
      return 'manifest malformed JSON';
    }
    if (decoded is! Map<String, dynamic>) {
      return 'manifest must be a JSON object';
    }
    for (final field in _identity.entries) {
      if (decoded[field.key] != field.value) {
        return 'manifest ${field.key} mismatch';
      }
    }
    final files = decoded['files'];
    if (files is! Map<String, dynamic>) {
      return 'manifest files must be a JSON object';
    }
    for (final abi in _abis.keys) {
      final relativePath = '$abi/librive_native.so';
      if (!files.containsKey(relativePath)) {
        return 'manifest missing $relativePath';
      }
      final digest = files[relativePath];
      if (digest is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
        return 'manifest invalid SHA-256 for $relativePath';
      }
    }
    if (files.length != _abis.length) {
      return 'manifest contains unexpected library entries';
    }
    try {
      await _artifactDigests(expected: files);
    } on FormatException catch (error) {
      return error.message;
    }
    return null;
  }

  Future<void> invalidate() async {
    if (await manifest.exists()) await manifest.delete();
  }

  /// Called only after setup's patched source build has succeeded.
  Future<void> recordSuccessfulBuild() async {
    await invalidate();
    final digests = await _artifactDigests();
    try {
      await manifest.writeAsString(
        jsonEncode({..._identity, 'files': digests}),
        flush: true,
      );
    } on FileSystemException {
      await invalidate();
      rethrow;
    }
  }

  Future<Map<String, String>> _artifactDigests({
    Map<String, dynamic>? expected,
  }) async {
    final digests = <String, String>{};
    for (final abi in _abis.entries) {
      final relativePath = '${abi.key}/librive_native.so';
      final file = File('${directory.path}/$relativePath');
      if (!await file.exists()) {
        throw FormatException('missing library $relativePath');
      }
      final handle = await file.open();
      late Uint8List bytes;
      try {
        bytes = await handle.read(64);
      } finally {
        await handle.close();
      }
      _validateElf(bytes, relativePath, abi.value);
      final digest = await calculateShaSum(file.path, algorithm: 256);
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
        throw Exception('Invalid SHA-256 tool output for $relativePath');
      }
      if (expected != null && digest != expected[relativePath]) {
        throw FormatException('SHA-256 mismatch for $relativePath');
      }
      digests[relativePath] = digest;
    }
    return digests;
  }

  void _validateElf(
    Uint8List bytes,
    String relativePath,
    ({int elfClass, int machine}) abi,
  ) {
    final headerSize = abi.elfClass == 1 ? 52 : 64;
    if (bytes.length < headerSize ||
        bytes[0] != 0x7f ||
        bytes[1] != 0x45 ||
        bytes[2] != 0x4c ||
        bytes[3] != 0x46 ||
        bytes[5] != 1 ||
        bytes[6] != 1) {
      throw FormatException('invalid ELF header for $relativePath');
    }
    final header = ByteData.sublistView(bytes);
    if (header.getUint32(20, Endian.little) != 1) {
      throw FormatException('invalid ELF version for $relativePath');
    }
    if (bytes[4] != abi.elfClass) {
      throw FormatException('ELF class mismatch for $relativePath');
    }
    if (header.getUint16(16, Endian.little) != 3) {
      throw FormatException('ELF type mismatch for $relativePath');
    }
    if (header.getUint16(18, Endian.little) != abi.machine) {
      throw FormatException('ELF machine mismatch for $relativePath');
    }
  }
}

Future<void> validateAndroidNdk(String? ndkPath) async {
  if (ndkPath == null || ndkPath.trim().isEmpty) {
    throw Exception('NDK_PATH must point to Android NDK $androidNdkVersion');
  }
  final properties = File('$ndkPath/source.properties');
  if (!await properties.exists()) {
    throw Exception('NDK source.properties not found at ${properties.path}');
  }
  final contents = await properties.readAsString();
  final revision = RegExp(
    r'^\s*Pkg\.Revision\s*=\s*(\S+)\s*$',
    multiLine: true,
  ).firstMatch(contents)?.group(1);
  if (revision != androidNdkVersion) {
    throw Exception(
      'NDK_PATH version mismatch: expected $androidNdkVersion, '
      'found ${revision ?? '<missing>'}',
    );
  }
}

Future<String> calculateShaSum(String filePath, {int algorithm = 512}) async {
  ProcessResult result;

  if (Platform.isWindows) {
    String algoFlag;
    switch (algorithm) {
      case 256:
        algoFlag = 'SHA256';
        break;
      case 512:
        algoFlag = 'SHA512';
        break;
      default:
        throw UnsupportedError(
          'Algorithm not supported on Windows: SHA-$algorithm',
        );
    }
    result = await Process.run('CertUtil', ['-hashfile', filePath, algoFlag]);
    if (result.exitCode != 0) {
      throw Exception(
        'Failed to calculate SHA checksum on Windows: ${result.stderr}',
      );
    }
    // CertUtil puts the checksum on the second output line.
    String checksum = result.stdout.toString().split('\n')[1].trim();
    return checksum;
  } else {
    result = await Process.run('shasum', ['-a', '$algorithm', filePath]);
    if (result.exitCode != 0) {
      throw Exception(
        'Failed to calculate SHA checksum on Unix-like systems: ${result.stderr}',
      );
    }
    String checksum = result.stdout.toString().split(' ').first.trim();
    return checksum;
  }
}
