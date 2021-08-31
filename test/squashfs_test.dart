import 'dart:io';

import 'package:squashfs/squashfs.dart';

import 'package:test/test.dart';

void main() {
  test('read file', () async {
    var file = SquashfsFile(Directory.current.path + '/test/test.squashfs');
    await file.read();
  });
}
