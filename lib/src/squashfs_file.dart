import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

enum SquashFsCompression { none, gzip, lzma, lzo, xz, lz4, zstd }

enum SquashfsInodeType {
  basicDirectory,
  basicFile,
  basicSymlink,
  basicBlockDevice,
  basicCharDevice,
  basicFifo,
  basicSocket,
  extendedDirectory,
  extendedFile,
  extendedSymlink,
  extendedBlockDevice,
  extendedCharDevice,
  extendedFifo,
  extendedSocket
}

abstract class SquashfsInode {
  final int uidIndex;
  final int gidIndex;
  final int modifiedTime;
  final int inodeNumber;

  SquashfsInode(
      {required this.uidIndex,
      required this.gidIndex,
      required this.modifiedTime,
      required this.inodeNumber});
}

class SquashfsBasicDirectoryInode extends SquashfsInode {
  final int parentInodeNumber;

  SquashfsBasicDirectoryInode(
      {required int uidIndex,
      required int gidIndex,
      required int modifiedTime,
      required int inodeNumber,
      required this.parentInodeNumber})
      : super(
            uidIndex: uidIndex,
            gidIndex: gidIndex,
            modifiedTime: modifiedTime,
            inodeNumber: inodeNumber);

  @override
  String toString() =>
      'SquashfsBasicDirectoryInode(inodeNumber: $inodeNumber, parentInodeNumber: $parentInodeNumber)';
}

class SquashfsBasicFileInode extends SquashfsInode {
  final int fileSize;

  SquashfsBasicFileInode(
      {required int uidIndex,
      required int gidIndex,
      required int modifiedTime,
      required int inodeNumber,
      required this.fileSize})
      : super(
            uidIndex: uidIndex,
            gidIndex: gidIndex,
            modifiedTime: modifiedTime,
            inodeNumber: inodeNumber);

  @override
  String toString() =>
      'SquashfsBasicFileInode(inodeNumber: $inodeNumber, fileSize: $fileSize)';
}

class SquashfsBasicSymlinkInode extends SquashfsInode {
  final String targetPath;

  SquashfsBasicSymlinkInode(
      {required int uidIndex,
      required int gidIndex,
      required int modifiedTime,
      required int inodeNumber,
      required this.targetPath})
      : super(
            uidIndex: uidIndex,
            gidIndex: gidIndex,
            modifiedTime: modifiedTime,
            inodeNumber: inodeNumber);

  @override
  String toString() =>
      'SquashfsBasicSymlinkInode(inodeNumber: $inodeNumber, targetPath: $targetPath)';
}

class SquashfsDirectoryEntry {
  final int inodeNumber;
  final String name;

  SquashfsDirectoryEntry({required this.inodeNumber, required this.name});

  @override
  String toString() =>
      'SquashfsDirectoryEntry(inodeNumber: $inodeNumber, name: $name)';
}

class SquashfsFile {
  final File _file;

  late final Endian _endian;
  late final int _blockSize;
  late final SquashFsCompression _compression;
  late final int _flags;

  late final List<SquashfsInode> _inodes;
  late final List<SquashfsDirectoryEntry> _directoryEntries;

  List<SquashfsInode> get inodes => _inodes;
  List<SquashfsDirectoryEntry> get directoryEntries => _directoryEntries;

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

    if (versionMajor != 4) {
      throw 'Unsupported squashfs version $versionMajor.$versionMinor';
    }

    _inodes = await _readInodeTable(
        file, inodeTableStart, directoryTableStart, inodeCount);
    _directoryEntries = await _readDirectoryTable(
        file, directoryTableStart, fragmentTableStart);

    file.close();
  }

  Future<Uint8List> _readMetadata(
      RandomAccessFile file, int start, int end) async {
    var builder = BytesBuilder();
    await file.setPosition(start);
    var offset = start;
    while (offset < end) {
      var blockLength =
          ByteData.sublistView(await file.read(2)).getUint16(0, _endian);
      var compressed = blockLength & 0x8000 == 0;
      blockLength &= 0x7fff;

      var data = await file.read(blockLength);
      if (compressed) {
        builder.add(_decompress(data));
      } else {
        builder.add(data);
      }
      offset += 2 + blockLength;
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
      var inodeTypeId = buffer.getUint16(offset + 0, _endian);
      var permissions = buffer.getUint16(offset + 2, _endian);
      var uidIndex = buffer.getUint16(offset + 4, _endian);
      var gidIndex = buffer.getUint16(offset + 6, _endian);
      var modifiedTime = buffer.getUint32(offset + 8, _endian);
      var inodeNumber = buffer.getUint32(offset + 12, _endian);
      offset += 16;

      if (inodeTypeId == 0 || inodeTypeId > SquashfsInodeType.values.length) {
        throw 'Unknown inode type $inodeTypeId';
      }
      var inodeType = SquashfsInodeType.values[inodeTypeId - 1];

      switch (inodeType) {
        case SquashfsInodeType.basicDirectory:
          var dirBlockStart = buffer.getUint32(offset + 0, _endian);
          var hardLinkCount = buffer.getUint32(offset + 4, _endian);
          var fileSize = buffer.getUint16(offset + 8, _endian);
          var blockOffset = buffer.getUint16(offset + 10, _endian);
          var parentInodeNumber = buffer.getUint32(offset + 12, _endian);
          offset += 16;
          inodes.add(SquashfsBasicDirectoryInode(
              uidIndex: uidIndex,
              gidIndex: gidIndex,
              modifiedTime: modifiedTime,
              inodeNumber: inodeNumber,
              parentInodeNumber: parentInodeNumber));
          break;
        case SquashfsInodeType.basicFile:
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
              uidIndex: uidIndex,
              gidIndex: gidIndex,
              modifiedTime: modifiedTime,
              inodeNumber: inodeNumber,
              fileSize: fileSize));
          break;
        case SquashfsInodeType.basicSymlink:
          var hardLinkCount = buffer.getUint32(offset + 0, _endian);
          var targetSize = buffer.getUint32(offset + 4, _endian);
          var targetPath =
              utf8.decode(data.sublist(offset + 8, offset + 8 + targetSize));
          offset += 8 + targetSize;
          inodes.add(SquashfsBasicSymlinkInode(
              uidIndex: uidIndex,
              gidIndex: gidIndex,
              modifiedTime: modifiedTime,
              inodeNumber: inodeNumber,
              targetPath: targetPath));
          break;
        default:
          throw 'Unknown inode type $inodeType';
      }
    }

    return inodes;
  }

  Future<List<SquashfsDirectoryEntry>> _readDirectoryTable(
      RandomAccessFile file, int start, int end) async {
    var entries = <SquashfsDirectoryEntry>[];

    var data = await _readMetadata(file, start, end);
    var buffer = ByteData.sublistView(data);

    var offset = 0;
    while (start + offset < end) {
      var count = buffer.getUint32(offset + 0, _endian) + 1;
      /*var inodeOffsetBase = */ buffer.getUint32(offset + 4, _endian);
      var inodeNumberBase = buffer.getUint32(offset + 8, _endian);
      offset += 12;
      for (var i = 0; i < count; i++) {
        /*var inodeOffset = */ buffer.getUint16(offset + 0, _endian);
        var inodeNumberOffset = buffer.getInt16(offset + 2, _endian);
        var type = buffer.getUint16(offset + 4, _endian);
        var nameSize = buffer.getUint16(offset + 6, _endian) + 1;
        var name = utf8.decode(data.sublist(offset + 8, offset + 8 + nameSize));
        offset += 8 + nameSize;

        entries.add(SquashfsDirectoryEntry(
            inodeNumber: inodeNumberBase + inodeNumberOffset, name: name));
      }
    }

    return entries;
  }
}
