import 'package:flutter/material.dart';

import '../screens/map_screen.dart';

class FreeWaterApp extends StatelessWidget {
  const FreeWaterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DarmowaKranówka',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
        ),
      ),
      home: const MapScreen(),
    );
  }
}