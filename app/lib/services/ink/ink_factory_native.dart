import 'dart:io' show Platform;
import 'digital_ink_common.dart';
import 'digital_ink_native.dart';
export 'digital_ink_native.dart';

DigitalInkEngine createDigitalInkEngine() =>
    Platform.isAndroid ? MlKitDigitalInkEngine() : HeuristicDigitalInkEngine();
