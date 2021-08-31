import 'dart:io';
import 'dart:typed_data';

class SquashfsFile {
  final File _file;

  late final int _flags;
  late final int _idTableStart;
  late final int _xattrIdTableStart;
  late final int _inodeTableStart;
  late final int _directoryTableStart;
  late final int _fragmentTableStart;
  late final int _exportTableStart;

  SquashfsFile(String filename) : _file = File(filename);

  Future<void> read() async {
    var file = await _file.open();

    var superblock = await file.read(96);
    if (superblock.length != 96) {
      throw 'Insufficient data for squashfs superblock';
    }
    var buffer = ByteData.sublistView(superblock);
    var endian = Endian.little;
    var magic = buffer.getUint32(0, endian);
    if (magic != 0x73717368) {
      endian = Endian.big;
      magic = buffer.getUint32(0, endian);
      if (magic != 0x73717368) {
        throw 'Invalid magic';
      }
    }
    var inodeCount = buffer.getUint32(4, endian);
    var modificationTime = buffer.getUint32(8, endian);
    var blockSize = buffer.getUint32(12, endian);
    var fragmentEntryCount = buffer.getUint32(16, endian);
    var compressionId = buffer.getUint16(20, endian);
    var blockLog = buffer.getUint16(22, endian);
    _flags = buffer.getUint16(24, endian);
    var idCount = buffer.getUint16(26, endian);
    var versionMajor = buffer.getUint16(28, endian);
    var versionMinor = buffer.getUint16(30, endian);
    var rootInodeRef = buffer.getUint64(32, endian);
    var bytesUsed = buffer.getUint64(40, endian);
    _idTableStart = buffer.getUint64(48, endian);
    _xattrIdTableStart = buffer.getUint64(56, endian);
    _inodeTableStart = buffer.getUint64(64, endian);
    _directoryTableStart = buffer.getUint64(72, endian);
    _fragmentTableStart = buffer.getUint64(80, endian);
    _exportTableStart = buffer.getUint64(88, endian);

    print('version = $versionMajor.$versionMinor');
    print('compression = $compressionId');
    print('flags = ${_flags.toRadixString(2)}');

    file.close();
  }
}
