import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../bin/android_cache.dart';

const _revision = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherRevision = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _fixtureAbis = {
  'armeabi-v7a': (elfClass: 1, machine: 40),
  'arm64-v8a': (elfClass: 2, machine: 183),
  'x86': (elfClass: 1, machine: 3),
  'x86_64': (elfClass: 2, machine: 62),
};

Future<void> _writeLibraries(Directory directory) async {
  for (final abi in _fixtureAbis.entries) {
    final bytes = Uint8List(80);
    bytes.setRange(0, 7, [0x7f, 0x45, 0x4c, 0x46, abi.value.elfClass, 1, 1]);
    final header = ByteData.sublistView(bytes);
    header.setUint16(16, 3, Endian.little);
    header.setUint16(18, abi.value.machine, Endian.little);
    header.setUint32(20, 1, Endian.little);
    header.setUint16(
      abi.value.elfClass == 1 ? 40 : 52,
      abi.value.elfClass == 1 ? 52 : 64,
      Endian.little,
    );
    bytes[79] = 0x42;
    final file = File('${directory.path}/${abi.key}/librive_native.so');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }
}

void main() {
  late Directory temporary;
  late AndroidNativeCache cache;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'rive_android_cache_test_',
    );
    cache = AndroidNativeCache(
      Directory('${temporary.path}/jniLibs'),
      _revision,
    );
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test(
    'missing manifest and legacy completion markers cannot bypass validation',
    () async {
      await _writeLibraries(cache.directory);
      await File('${temporary.path}/rive_marker_android_development').create();
      await File('${temporary.path}/rive_marker_android_setup_complete')
          .create();
      expect(await cache.invalidReason(), isNotNull);
    },
  );

  test('records and validates all four ABI artifacts with SHA-256', () async {
    await _writeLibraries(cache.directory);
    await cache.recordSuccessfulBuild();
    expect(await cache.invalidReason(), isNull);
    final manifest =
        jsonDecode(await cache.manifest.readAsString()) as Map<String, dynamic>;
    final files = manifest['files'] as Map<String, dynamic>;
    expect(
      files.keys.toSet(),
      _fixtureAbis.keys.map((abi) => '$abi/librive_native.so').toSet(),
    );
    for (final digest in files.values) {
      expect(digest, matches(r'^[0-9a-f]{64}$'));
    }
  });

  test('cached directory can move without invalidating identity', () async {
    await _writeLibraries(cache.directory);
    await cache.recordSuccessfulBuild();
    final moved = Directory('${temporary.path}/restored');
    await moved.create();
    await for (final entity in cache.directory.list(recursive: true)) {
      if (entity is File) {
        final relative = entity.path.substring(cache.directory.path.length + 1);
        final target = File('${moved.path}/$relative');
        await target.parent.create(recursive: true);
        await entity.copy(target.path);
      }
    }
    expect(await AndroidNativeCache(moved, _revision).invalidReason(), isNull);
  });

  test('malformed or non-object manifest gives a cache-miss reason', () async {
    await cache.directory.create(recursive: true);
    for (final contents in ['{', '[]', 'null', '"manifest"']) {
      await cache.manifest.writeAsString(contents);
      expect(await cache.invalidReason(), isNotNull);
    }
  });

  test('every manifest identity field must match exactly', () async {
    await _writeLibraries(cache.directory);
    await cache.recordSuccessfulBuild();
    final original = await cache.manifest.readAsString();
    for (final field in [
      'schemaVersion',
      'key',
      'revision',
      'ndkVersion',
      'configuration',
    ]) {
      final manifest = jsonDecode(original) as Map<String, dynamic>;
      manifest[field] = 'different';
      await cache.manifest.writeAsString(jsonEncode(manifest));
      expect(await cache.invalidReason(), isNotNull);
    }
    await cache.manifest.writeAsString(original);
    expect(
      await AndroidNativeCache(cache.directory, _otherRevision).invalidReason(),
      isNotNull,
    );
  });

  test('missing ABI file invalidates an otherwise valid manifest', () async {
    await _writeLibraries(cache.directory);
    await cache.recordSuccessfulBuild();
    await File('${cache.directory.path}/x86/librive_native.so').delete();
    expect(await cache.invalidReason(), isNotNull);
  });

  test(
    'missing ABI digest, malformed digests and extra entries are rejected',
    () async {
      await _writeLibraries(cache.directory);
      await cache.recordSuccessfulBuild();
      final original = await cache.manifest.readAsString();
      Map<String, dynamic> manifest = jsonDecode(original);
      (manifest['files'] as Map<String, dynamic>).remove(
        'arm64-v8a/librive_native.so',
      );
      await cache.manifest.writeAsString(jsonEncode(manifest));
      expect(await cache.invalidReason(), isNotNull);

      for (final digest in [null, 123, 'short']) {
        manifest = jsonDecode(original);
        manifest['files']['arm64-v8a/librive_native.so'] = digest;
        await cache.manifest.writeAsString(jsonEncode(manifest));
        expect(await cache.invalidReason(), isNotNull);
      }
      manifest = jsonDecode(original);
      manifest['files']['unexpected/librive_native.so'] =
          manifest['files']['x86/librive_native.so'];
      await cache.manifest.writeAsString(jsonEncode(manifest));
      expect(await cache.invalidReason(), isNotNull);

      manifest = jsonDecode(original);
      manifest['files'] = [];
      await cache.manifest.writeAsString(jsonEncode(manifest));
      expect(await cache.invalidReason(), isNotNull);
    },
  );

  test(
    'payload corruption is rejected even when ELF header is unchanged',
    () async {
      await _writeLibraries(cache.directory);
      await cache.recordSuccessfulBuild();
      final file = File('${cache.directory.path}/x86_64/librive_native.so');
      final bytes = await file.readAsBytes();
      bytes[bytes.length - 1] ^= 1;
      await file.writeAsBytes(bytes);
      expect(await cache.invalidReason(), isNotNull);
    },
  );

  test('ELF class and machine are checked for every ABI', () async {
    await _writeLibraries(cache.directory);
    await cache.recordSuccessfulBuild();
    for (final abi in _fixtureAbis.entries) {
      final file = File('${cache.directory.path}/${abi.key}/librive_native.so');
      final original = await file.readAsBytes();
      final bytes = Uint8List.fromList(original);
      bytes[4] = abi.value.elfClass == 1 ? 2 : 1;
      await file.writeAsBytes(bytes);
      expect(await cache.invalidReason(), isNotNull);
      bytes.setAll(0, original);
      ByteData.sublistView(bytes).setUint16(18, 0, Endian.little);
      await file.writeAsBytes(bytes);
      expect(await cache.invalidReason(), isNotNull);
      await file.writeAsBytes(original);
    }
    expect(await cache.invalidReason(), isNull);
  });

  test(
    'ELF shared-object type, header, byte order and version are required',
    () async {
      await _writeLibraries(cache.directory);
      await cache.recordSuccessfulBuild();
      final file = File(
        '${cache.directory.path}/armeabi-v7a/librive_native.so',
      );
      final original = await file.readAsBytes();
      for (final change in [
        (offset: 0, value: 0),
        (offset: 5, value: 2),
        (offset: 6, value: 0),
        (offset: 16, value: 2),
        (offset: 20, value: 0),
      ]) {
        final bytes = Uint8List.fromList(original);
        bytes[change.offset] = change.value;
        await file.writeAsBytes(bytes);
        expect(await cache.invalidReason(), isNotNull);
      }
      await file.writeAsBytes(original.sublist(0, 20));
      expect(await cache.invalidReason(), isNotNull);
    },
  );

  test(
    '--clean rejects valid cache and invalidation removes completion metadata',
    () async {
      await _writeLibraries(cache.directory);
      await cache.recordSuccessfulBuild();
      expect(await cache.invalidReason(), isNull);
      expect(await cache.invalidReason(clean: true), isNotNull);
      await cache.invalidate();
      expect(await cache.manifest.exists(), isFalse);
      expect(await cache.invalidReason(), isNotNull);
      expect(
        await File('${cache.directory.path}/x86/librive_native.so').exists(),
        isTrue,
      );
    },
  );

  test(
    'invalid artifacts cannot leave an earlier successful manifest',
    () async {
      await _writeLibraries(cache.directory);
      await cache.recordSuccessfulBuild();
      await File('${cache.directory.path}/arm64-v8a/librive_native.so')
          .delete();
      await expectLater(cache.recordSuccessfulBuild(), throwsFormatException);
      expect(await cache.manifest.exists(), isFalse);
    },
  );

  test('real checksum tool failure propagates', () async {
    await expectLater(
      calculateShaSum('${temporary.path}/missing.so', algorithm: 256),
      throwsException,
    );
  });

  test(
    'source build requires source.properties with the pinned NDK revision',
    () async {
      final ndk = Directory('${temporary.path}/ndk');
      await ndk.create();
      final properties = File('${ndk.path}/source.properties');
      await expectLater(validateAndroidNdk(null), throwsException);
      await expectLater(validateAndroidNdk(''), throwsException);
      await expectLater(validateAndroidNdk(ndk.path), throwsException);
      for (final contents in [
        'Pkg.Desc = Android NDK\n',
        'Pkg.Revision = 26.3.11579264\n',
      ]) {
        await properties.writeAsString(contents);
        await expectLater(validateAndroidNdk(ndk.path), throwsException);
      }
      await properties.writeAsString(
        'Pkg.Desc = Android NDK\r\nPkg.Revision = 27.2.12479018\r\n',
      );
      await validateAndroidNdk(ndk.path);
    },
  );
}
