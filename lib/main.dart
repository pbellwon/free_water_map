import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(const FreeWaterApp());
}

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

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  Future<void> _showPlace(
    BuildContext context,
    DocumentReference<Object?> placeReference,
    String name,
    String address,
    int confirmations,
  ) async {
    var displayedConfirmations = confirmations;
    var isConfirming = false;
    var confirmedDuringThisOpening = false;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (bottomSheetContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            Future<void> confirmPlace() async {
              if (isConfirming || confirmedDuringThisOpening) {
                return;
              }

              setModalState(() {
                isConfirming = true;
              });

              try {
                await placeReference.update({
                  'confirmations': FieldValue.increment(1),
                  'lastConfirmedAt': FieldValue.serverTimestamp(),
                });

                if (!context.mounted) {
                  return;
                }

                setModalState(() {
                  displayedConfirmations++;
                  isConfirming = false;
                  confirmedDuringThisOpening = true;
                });

                ScaffoldMessenger.of(bottomSheetContext).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Dziękujemy za potwierdzenie.',
                    ),
                  ),
                );
              } catch (error) {
                if (!context.mounted) {
                  return;
                }

                setModalState(() {
                  isConfirming = false;
                });

                ScaffoldMessenger.of(bottomSheetContext).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Nie udało się zapisać potwierdzenia: $error',
                    ),
                  ),
                );
              }
            }

            return Padding(
              padding: const EdgeInsets.fromLTRB(
                24,
                8,
                24,
                24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(address),
                  const SizedBox(height: 16),
                  const Row(
                    children: [
                      Icon(
                        Icons.water_drop,
                        color: Colors.blue,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Darmowa woda do zamówienia',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Potwierdzone: $displayedConfirmations razy',
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor:
                            Colors.blue.withValues(alpha: 0.45),
                        disabledForegroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          vertical: 14,
                        ),
                      ),
                      onPressed:
                          isConfirming || confirmedDuringThisOpening
                              ? null
                              : confirmPlace,
                      child: isConfirming
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              confirmedDuringThisOpening
                                  ? 'Potwierdzono'
                                  : 'Potwierdzam',
                            ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _openAddPlaceScreen() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const AddPlaceScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: 12,
              sigmaY: 12,
            ),
            child: AppBar(
              backgroundColor:
                  Colors.white.withValues(alpha: 0.62),
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              title: const Text(
                'DarmowaKranówka',
                style: TextStyle(
                  color: Colors.blue,
                  fontWeight: FontWeight.w700,
                ),
              ),
              actions: [
                TextButton.icon(
                  onPressed: _openAddPlaceScreen,
                  icon: const Icon(
                    Icons.add_location_alt,
                    color: Colors.blue,
                  ),
                  label: const Text(
                    'Dodaj lokal',
                    style: TextStyle(
                      color: Colors.blue,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('places')
            .where('status', isEqualTo: 'active')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Błąd: ${snapshot.error}',
              ),
            );
          }

          if (snapshot.connectionState ==
              ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          final places = snapshot.data?.docs ?? [];

          return FlutterMap(
            options: const MapOptions(
              initialCenter: LatLng(
                54.5189,
                18.5305,
              ),
              initialZoom: 13,
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'pl.freewater.app',
              ),
              MarkerLayer(
                markers: places.map((doc) {
                  final data =
                      doc.data() as Map<String, dynamic>;

                  final name =
                      data['name'] as String? ?? 'Nieznany lokal';

                  final address =
                      data['address'] as String? ?? 'Brak adresu';

                  final location =
                      data['location'] as GeoPoint?;

                  final confirmations =
                      (data['confirmations'] as num?)?.toInt() ??
                          0;

                  if (location == null) {
                    return null;
                  }

                  return Marker(
                    point: LatLng(
                      location.latitude,
                      location.longitude,
                    ),
                    width: 50,
                    height: 50,
                    child: GestureDetector(
                      onTap: () => _showPlace(
                        context,
                        doc.reference,
                        name,
                        address,
                        confirmations,
                      ),
                      child: const Icon(
                        Icons.water_drop,
                        size: 42,
                        color: Colors.blue,
                      ),
                    ),
                  );
                }).whereType<Marker>().toList(),
              ),
              RichAttributionWidget(
                attributions: [
                  TextSourceAttribution(
                    'OpenStreetMap contributors',
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class AddPlaceScreen extends StatefulWidget {
  const AddPlaceScreen({super.key});

  @override
  State<AddPlaceScreen> createState() =>
      _AddPlaceScreenState();
}

class _AddPlaceScreenState extends State<AddPlaceScreen> {
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();

  LatLng? _selectedLocation;
  String _category = 'restaurant';
  bool _isSaving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _savePlace() async {
    final name = _nameController.text.trim();
    final address = _addressController.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Podaj nazwę lokalu.'),
        ),
      );
      return;
    }

    if (address.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Podaj adres lokalu.'),
        ),
      );
      return;
    }

    if (_selectedLocation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Wskaż lokal na mapie.'),
        ),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      await FirebaseFirestore.instance
          .collection('places')
          .add({
        'name': name,
        'address': address,
        'location': GeoPoint(
          _selectedLocation!.latitude,
          _selectedLocation!.longitude,
        ),
        'category': _category,
        'confirmations': 1,
        'status': 'active',
        'createdAt': FieldValue.serverTimestamp(),
        'lastConfirmedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) {
        return;
      }

      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isSaving = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się zapisać lokalu: $error',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dodaj lokal'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              16,
              16,
              16,
              8,
            ),
            child: Column(
              children: [
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Nazwa lokalu',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _addressController,
                  decoration: const InputDecoration(
                    labelText: 'Adres',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  decoration: const InputDecoration(
                    labelText: 'Rodzaj lokalu',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'restaurant',
                      child: Text('Restauracja'),
                    ),
                    DropdownMenuItem(
                      value: 'cafe',
                      child: Text('Kawiarnia'),
                    ),
                    DropdownMenuItem(
                      value: 'bar',
                      child: Text('Bar'),
                    ),
                    DropdownMenuItem(
                      value: 'other',
                      child: Text('Inne'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }

                    setState(() {
                      _category = value;
                    });
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(
                      Icons.location_on,
                      color: Colors.blue,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _selectedLocation == null
                            ? 'Kliknij miejsce lokalu na mapie'
                            : 'Lokalizacja wybrana',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: FlutterMap(
              options: MapOptions(
                initialCenter: const LatLng(
                  54.5189,
                  18.5305,
                ),
                initialZoom: 14,
                onTap: (tapPosition, point) {
                  setState(() {
                    _selectedLocation = point;
                  });
                },
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'pl.freewater.app',
                ),
                if (_selectedLocation != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: _selectedLocation!,
                        width: 50,
                        height: 50,
                        child: const Icon(
                          Icons.water_drop,
                          size: 42,
                          color: Colors.blue,
                        ),
                      ),
                    ],
                  ),
                RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution(
                      'OpenStreetMap contributors',
                    ),
                  ],
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                    ),
                  ),
                  onPressed:
                      _isSaving ? null : _savePlace,
                  child: _isSaving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Dodaj lokal'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}