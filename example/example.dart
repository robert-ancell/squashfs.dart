import 'package:squashfs/squashfs.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('Missing filename');
    return;
  }
  var filename = args.first;

  var file = SquashfsFile(filename);
  await file.read();
  print(file.directoryEntries);
  print(file.inodes);
}
