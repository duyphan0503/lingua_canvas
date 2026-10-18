import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'backup_file_transport_common.dart';

class WebBackupFileTransport extends SelectorBackupFileTransport {
  WebBackupFileTransport({super.pickFile})
    : super(
        saveFile: _downloadBackup,
        releaseFile: (file) {
          // file_selector_web creates a temporary object URL for each pick.
          if (file.path.startsWith('blob:')) _revokeObjectURL(file.path);
        },
      );
}

BackupFileTransport createBackupFileTransport() => WebBackupFileTransport();

Future<bool> _downloadBackup(
  Uint8List bytes, {
  required String suggestedName,
}) async {
  final blob = _Blob(
    <JSAny>[bytes.toJS].toJS,
    _BlobOptions(type: 'application/json'),
  );
  final url = _createObjectURL(blob);
  _Anchor? anchor;
  var downloaded = false;
  try {
    anchor = _document.createElement('a');
    anchor.href = url;
    anchor.download = suggestedName;
    _document.body?.appendChild(anchor);
    anchor.click();
    downloaded = true;
    return true;
  } finally {
    anchor?.remove();
    if (downloaded) {
      // The browser consumes the URL asynchronously after click returns.
      Timer(const Duration(seconds: 1), () => _revokeObjectURL(url));
    } else {
      _revokeObjectURL(url);
    }
  }
}

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external _Blob(JSArray<JSAny> parts, _BlobOptions options);
}

extension type _BlobOptions._(JSObject _) implements JSObject {
  external factory _BlobOptions({String type});
}

@JS('URL.createObjectURL')
external String _createObjectURL(_Blob blob);

@JS('URL.revokeObjectURL')
external void _revokeObjectURL(String url);

@JS('document')
external _Document get _document;

extension type _Document._(JSObject _) implements JSObject {
  external _Anchor createElement(String tag);
  external _Element? get body;
}

extension type _Element._(JSObject _) implements JSObject {
  external void appendChild(_Element child);
}

extension type _Anchor._(JSObject _) implements _Element {
  external set href(String value);
  external set download(String value);
  external void click();
  external void remove();
}
