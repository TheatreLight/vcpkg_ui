import 'package:flutter/material.dart';
import 'package:vcpkg_ui/app/vcpkg_ui_controller.dart';
import 'package:vcpkg_ui/presentation/vcpkg_home_screen.dart';

class VcpkgApp extends StatelessWidget {
  const VcpkgApp({super.key, required this.controller});

  final VcpkgUiController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vcpkg UI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff2266aa),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
        cardTheme: const CardThemeData(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
        ),
      ),
      home: VcpkgHomeScreen(controller: controller),
    );
  }
}
