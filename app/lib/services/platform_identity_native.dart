import 'dart:io' show Platform;

String currentDevicePlatform() => Platform.isAndroid ? 'android' : 'linux';
