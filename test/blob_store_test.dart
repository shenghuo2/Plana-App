import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/blob_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late BlobStore store;
  final bytes = Uint8List.fromList(List.generate(256, (i) => i));

  setUp(() {
    root = Directory.systemTemp.createTempSync('plana_blob');
    store = BlobStore(root);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('同一参考图并发写入:所有调用成功且只落一份完整 blob', () async {
    final hash = await store.hashOf(bytes);
    final hashes = await Future.wait([
      for (var i = 0; i < 24; i++)
        store.put(Uint8List.fromList(bytes), known: i.isEven ? hash : null),
    ]);

    expect(hashes, everyElement(hash));
    expect(await store.get(hash), bytes);
    expect(
      Directory('${root.path}/blobs').listSync().map((file) => file.path),
      ['${root.path}/blobs/$hash.bin'],
    );
  });

  test('并发写入失败后:修复目录即可重试同一 blob', () async {
    final hash = await store.hashOf(bytes);
    final blockedTemp = Directory('${root.path}/blobs/$hash.bin.tmp');
    await blockedTemp.create(recursive: true);

    await expectLater(
      Future.wait([store.put(bytes), store.put(bytes)]),
      throwsA(isA<FileSystemException>()),
    );

    await blockedTemp.delete();
    expect(await store.put(bytes), hash);
    expect(await store.get(hash), bytes);
  });
}
