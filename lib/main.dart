import 'package:flutter/material.dart';
import 'package:vcpkg_ui/app/composition_root.dart';
import 'package:vcpkg_ui/presentation/vcpkg_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(VcpkgApp(controller: createVcpkgUiController()));
}
