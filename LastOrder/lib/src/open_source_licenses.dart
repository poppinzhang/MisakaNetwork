import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'app_info.dart';

const thirdPartyLicensesAsset = 'assets/licenses/third_party_licenses.json';

Future<void>? _registration;

/// Reads the bundled notices without dropping malformed or incomplete entries.
Future<List<LicenseEntry>> loadOpenSourceLicenseEntries(
  AssetBundle bundle,
) async {
  final decoded = jsonDecode(
    await bundle.loadString(thirdPartyLicensesAsset, cache: false),
  );
  if (decoded is! List || decoded.isEmpty) {
    throw const FormatException(
      'The bundled license list is empty or invalid.',
    );
  }
  return decoded
      .map<LicenseEntry>((entry) {
        if (entry is! Map<String, dynamic> ||
            entry['packages'] is! List ||
            (entry['packages'] as List).isEmpty ||
            !(entry['packages'] as List).every(
              (name) => name is String && name.trim().isNotEmpty,
            ) ||
            entry['text'] is! String ||
            (entry['text'] as String).trim().isEmpty) {
          throw const FormatException('A bundled license entry is incomplete.');
        }
        return LicenseEntryWithLineBreaks(
          List<String>.from(entry['packages'] as List),
          entry['text'] as String,
        );
      })
      .toList(growable: false);
}

Future<void> _registerOpenSourceLicenses(AssetBundle bundle) {
  return _registration ??=
      () async {
        final entries = await loadOpenSourceLicenseEntries(bundle);
        LicenseRegistry.addLicense(
          () => Stream<LicenseEntry>.fromIterable(entries),
        );
      }().catchError((Object error, StackTrace stack) {
        // A failed read must not prevent another attempt or register a partial list.
        _registration = null;
        Error.throwWithStackTrace(error, stack);
      });
}

@visibleForTesting
void resetOpenSourceLicenseRegistration() {
  _registration = null;
}

void showOpenSourceLicenses(BuildContext context) {
  final navigator = Navigator.of(context);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  final bundle = DefaultAssetBundle.of(context);
  navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => themes.wrap(_OpenSourceLicensesPage(bundle: bundle)),
    ),
  );
}

class _OpenSourceLicensesPage extends StatefulWidget {
  const _OpenSourceLicensesPage({required this.bundle});

  final AssetBundle bundle;

  @override
  State<_OpenSourceLicensesPage> createState() =>
      _OpenSourceLicensesPageState();
}

class _OpenSourceLicensesPageState extends State<_OpenSourceLicensesPage> {
  late Future<void> _ready;

  @override
  void initState() {
    super.initState();
    _ready = _registerOpenSourceLicenses(widget.bundle);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done &&
            !snapshot.hasError) {
          return const LicensePage(
            applicationName: 'LastOrder',
            applicationVersion: '$appVersion · 构建 $appBuildNumber',
            applicationLegalese: '第三方组件的许可原文与版权声明',
          );
        }
        return Scaffold(
          appBar: AppBar(title: const Text('开源许可')),
          body: Center(
            child: snapshot.hasError
                ? SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('无法读取开源许可，请重试。'),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: () => setState(() {
                            _ready = _registerOpenSourceLicenses(widget.bundle);
                          }),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  )
                : const CircularProgressIndicator(),
          ),
        );
      },
    );
  }
}
