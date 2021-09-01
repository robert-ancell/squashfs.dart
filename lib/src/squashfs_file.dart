import 'dart:io';
import 'dart:typed_data';

enum SquashFsCompression { none, gzip, lzma, lzo, xz, lz4, zstd }

class SquashfsInode {
  final int uidIdx;
  final int gidIdx;
  final int modifiedTime;
  final int inodeNumber;

  SquashfsInode(
      {required this.uidIdx,
      required this.gidIdx,
      required this.modifiedTime,
      required this.inodeNumber});
}

class SquashfsBasicDirectoryInode extends SquashfsInode {
  SquashfsBasicDirectoryInode(
      {required int uidIdx,
      required int gidIdx,
      required int modifiedTime,
      required int inodeNumber})
      : super(
            uidIdx: uidIdx,
            gidIdx: gidIdx,
            modifiedTime: modifiedTime,
            inodeNumber: inodeNumber);
}

class SquashfsBasicFileInode extends SquashfsInode {
  SquashfsBasicFileInode(
      {required int uidIdx,
      required int gidIdx,
      required int modifiedTime,
      required int inodeNumber})
      : super(
            uidIdx: uidIdx,
            gidIdx: gidIdx,
            modifiedTime: modifiedTime,
            inodeNumber: inodeNumber);
}

class SquashfsBasicSymlinkInode extends SquashfsInode {
  SquashfsBasicSymlinkInode(
      {required int uidIdx,
      required int gidIdx,
      required int modifiedTime,
      required int inodeNumber})
      : super(
            uidIdx: uidIdx,
            gidIdx: gidIdx,
            modifiedTime: modifiedTime,
            inodeNumber: inodeNumber);
}

class SquashfsFile {
  final File _file;

  late final Endian _endian;
  late final int _blockSize;
  late final SquashFsCompression _compression;
  late final int _flags;

  late final List<SquashfsInode> _inodes;

  SquashfsFile(String filename) : _file = File(filename);

  Future<void> read() async {
    var file = await _file.open();

    var superblock = await file.read(96);
    if (superblock.length != 96) {
      throw 'Insufficient data for squashfs superblock';
    }
    var buffer = ByteData.sublistView(superblock);
    _endian = Endian.little;
    var magic = buffer.getUint32(0, _endian);
    if (magic != 0x73717368) {
      _endian = Endian.big;
      magic = buffer.getUint32(0, _endian);
      if (magic != 0x73717368) {
        throw 'Invalid magic';
      }
    }
    var inodeCount = buffer.getUint32(4, _endian);
    var modificationTime = buffer.getUint32(8, _endian);
    _blockSize = buffer.getUint32(12, _endian);
    var fragmentEntryCount = buffer.getUint32(16, _endian);
    var compressionId = buffer.getUint16(20, _endian);
    if (compressionId >= SquashFsCompression.values.length) {
      throw 'Unknown compression ID $compressionId';
    }
    _compression = SquashFsCompression.values[compressionId];
    var blockLog = buffer.getUint16(22, _endian);
    _flags = buffer.getUint16(24, _endian);
    var idCount = buffer.getUint16(26, _endian);
    var versionMajor = buffer.getUint16(28, _endian);
    var versionMinor = buffer.getUint16(30, _endian);
    var rootInodeRef = buffer.getUint64(32, _endian);
    var bytesUsed = buffer.getUint64(40, _endian);
    var idTableStart = buffer.getUint64(48, _endian);
    var xattrIdTableStart = buffer.getUint64(56, _endian);
    var inodeTableStart = buffer.getUint64(64, _endian);
    var directoryTableStart = buffer.getUint64(72, _endian);
    var fragmentTableStart = buffer.getUint64(80, _endian);
    var exportTableStart = buffer.getUint64(88, _endian);

    print('version = $versionMajor.$versionMinor');
    print('compression = $_compression');
    print('flags = ${_flags.toRadixString(2)}');

    _inodes = await _readInodeTable(
        file, inodeTableStart, directoryTableStart, inodeCount);
    print(_inodes);

    file.close();
  }

  Future<Uint8List> _readMetadata(
      RandomAccessFile file, int start, int end) async {
    var builder = BytesBuilder();
    var offset = start;
    while (offset < end) {
      await file.setPosition(offset);
      var blockLength =
          ByteData.sublistView(await file.read(2)).getUint16(0, _endian);
      var data = await file.read(blockLength & 0x7fff);
      if (blockLength & 0x8000 == 0) {
        builder.add(_decompress(data));
      } else {
        builder.add(data);
      }
      offset += 2 + blockLength & 0x7fff;
    }
    return builder.takeBytes();
  }

  List<int> _decompress(Uint8List data) {
    switch (_compression) {
      case SquashFsCompression.gzip:
        return gzip.decode(data);
      default:
        throw 'Unsupported compression format $_compression';
    }
  }

  Future<List<SquashfsInode>> _readInodeTable(
      RandomAccessFile file, int start, int end, int inodeCount) async {
    var inodes = <SquashfsInode>[];

    var data = await _readMetadata(file, start, end);
    var buffer = ByteData.sublistView(data);

    var offset = 0;
    for (var i = 0; i < inodeCount; i++) {
      var inodeType = buffer.getUint16(offset + 0, _endian);
      var permissions = buffer.getUint16(offset + 2, _endian);
      var uidIdx = buffer.getUint16(offset + 4, _endian);
      var gidIdx = buffer.getUint16(offset + 6, _endian);
      var modifiedTime = buffer.getUint32(offset + 8, _endian);
      var inodeNumber = buffer.getUint32(offset + 12, _endian);
      offset += 16;

      switch (inodeType) {
        case 1: // Basic Directory
          var dirBlockStart = buffer.getUint32(offset + 0, _endian);
          var hardLinkCount = buffer.getUint32(offset + 4, _endian);
          var fileSize = buffer.getUint16(offset + 8, _endian);
          var blockOffset = buffer.getUint16(offset + 10, _endian);
          var parentInodeNumber = buffer.getUint32(offset + 12, _endian);
          offset += 16;
          inodes.add(SquashfsBasicDirectoryInode(
              uidIdx: uidIdx,
              gidIdx: gidIdx,
              modifiedTime: modifiedTime,
              inodeNumber: inodeNumber));
          break;
        case 2: // Basic File
          var blocksStart = buffer.getUint32(offset + 0, _endian);
          var fragmentBlockIndex = buffer.getUint32(offset + 4, _endian);
          var blockOffset = buffer.getUint32(offset + 8, _endian);
          var fileSize = buffer.getUint32(offset + 12, _endian);
          offset += 16;
          var nFullBlocks = fileSize ~/ _blockSize;
          var blockSizes = <int>[];
          for (var j = 0; j < nFullBlocks; j++) {
            var blockSize = buffer.getUint32(offset, _endian);
            blockSizes.add(blockSize);
            offset += 4;
          }
          inodes.add(SquashfsBasicFileInode(
              uidIdx: uidIdx,
              gidIdx: gidIdx,
              modifiedTime: modifiedTime,
              inodeNumber: inodeNumber));
          break;
        default:
          throw 'Unknown inode type $inodeType';
      }
    }

    return inodes;
  }
}
