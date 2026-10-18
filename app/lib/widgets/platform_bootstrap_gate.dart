import 'dart:async';
import 'package:flutter/material.dart';
import '../services/local_database.dart';
import '../services/platform_bootstrap.dart';

class PlatformBootstrapGate extends StatefulWidget {
  final Widget child;
  final Future<void> Function()? initialize;
  final Future<void> Function()? close;
  const PlatformBootstrapGate({
    super.key,
    required this.child,
    this.initialize,
    this.close,
  });
  @override
  State<PlatformBootstrapGate> createState() => _PlatformBootstrapGateState();
}

class _PlatformBootstrapGateState extends State<PlatformBootstrapGate> {
  late Future<void> _ready;
  Future<void> _close() async {
    if (widget.close != null) {
      await widget.close!();
    } else if (widget.initialize == null) {
      await LocalDatabase.instance.close();
    }
  }

  Future<void> _initialize() async {
    await (widget.initialize?.call() ??
        initializePlatformStorage(LocalDatabase.instance));
    if (!mounted) {
      await _close();
    }
  }

  @override
  void initState() {
    super.initState();
    _ready = _initialize();
  }

  @override
  void dispose() {
    unawaited(_close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _ready,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.done &&
          !snapshot.hasError) {
        return widget.child;
      }
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Lingua Canvas',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (snapshot.hasError) ...[
                      const Text(
                        'Chưa mở được dữ liệu học tập',
                        style: TextStyle(fontSize: 18),
                      ),
                      const SizedBox(height: 12),
                      Text('${snapshot.error}', textAlign: TextAlign.center),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: () => setState(() {
                          _ready = _initialize();
                        }),
                        child: const Text('Thử lại'),
                      ),
                    ] else ...[
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      const Text('Đang mở dữ liệu học tập...'),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
