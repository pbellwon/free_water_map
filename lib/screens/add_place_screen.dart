import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/nearby_place.dart';

class AddPlaceScreen extends StatefulWidget {
  const AddPlaceScreen({super.key});

  @override
  State<AddPlaceScreen> createState() =>
      _AddPlaceScreenState();
}

class _AddPlaceScreenState extends State<AddPlaceScreen> {
  static const double _duplicateRadiusMeters = 150;

  final _nameController = TextEditingController();

  final Distance _distanceCalculator = const Distance();

  LatLng? _selectedLocation;
  String? _resolvedAddress;

  String _category = 'restaurant';

  bool _isResolvingAddress = false;
  bool _isSaving = false;

  DateTime? _lastAddressRequest;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<List<NearbyPlace>> _findNearbyPlaces(
    LatLng selectedLocation,
  ) async {
    final snapshot = await FirebaseFirestore.instance
        .collection('places')
        .where(
          'status',
          whereIn: [
            'pending',
            'confirmed',
            'disputed',
          ],
        )
        .get();

    final nearbyPlaces = <NearbyPlace>[];

    for (final document in snapshot.docs) {
      final data = document.data();

      final location =
          data['location'] as GeoPoint?;

      if (location == null) {
        continue;
      }

      final placeLocation = LatLng(
        location.latitude,
        location.longitude,
      );

      final distanceMeters =
          _distanceCalculator(
        selectedLocation,
        placeLocation,
      );

      if (distanceMeters <=
          _duplicateRadiusMeters) {
        nearbyPlaces.add(
          NearbyPlace(
            name:
                data['name'] as String? ??
                    'Nieznany lokal',
            address:
                data['address'] as String? ??
                    'Brak adresu',
            distanceMeters: distanceMeters,
          ),
        );
      }
    }

    nearbyPlaces.sort(
      (first, second) =>
          first.distanceMeters.compareTo(
        second.distanceMeters,
      ),
    );

    return nearbyPlaces;
  }

  Future<bool> _checkForDuplicates(
    LatLng selectedLocation,
  ) async {
    final nearbyPlaces =
        await _findNearbyPlaces(
      selectedLocation,
    );

    if (nearbyPlaces.isEmpty) {
      return true;
    }

    if (!mounted) {
      return false;
    }

    final shouldAddAnyway =
        await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          icon: const Icon(
            Icons.warning_amber_rounded,
            color: Colors.orange,
            size: 34,
          ),
          title: const Text(
            'Lokal może już istnieć',
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 460,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize:
                    MainAxisSize.min,
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  const Text(
                    'W promieniu 150 metrów znaleźliśmy:',
                  ),
                  const SizedBox(height: 14),

                  ...nearbyPlaces.take(3).map(
                    (place) {
                      return Padding(
                        padding:
                            const EdgeInsets.only(
                          bottom: 12,
                        ),
                        child: Row(
                          crossAxisAlignment:
                              CrossAxisAlignment
                                  .start,
                          children: [
                            const Icon(
                              Icons.water_drop,
                              color: Colors.blue,
                              size: 22,
                            ),
                            const SizedBox(
                              width: 10,
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment
                                        .start,
                                children: [
                                  Text(
                                    place.name,
                                    style:
                                        const TextStyle(
                                      fontWeight:
                                          FontWeight
                                              .w700,
                                    ),
                                  ),
                                  const SizedBox(
                                    height: 2,
                                  ),
                                  Text(
                                    place.address,
                                  ),
                                  const SizedBox(
                                    height: 2,
                                  ),
                                  Text(
                                    'Około '
                                    '${place.distanceMeters.round()} m '
                                    'od wybranego miejsca',
                                    style:
                                        const TextStyle(
                                      fontSize: 12,
                                      color:
                                          Colors.black54,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),

                  const Text(
                    'Dodaj nowy wpis tylko wtedy, '
                    'gdy jest to inny lokal.',
                    style: TextStyle(
                      fontWeight:
                          FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(
                  dialogContext,
                ).pop(false);
              },
              child: const Text(
                'Anuluj',
              ),
            ),
            FilledButton(
              style:
                  FilledButton.styleFrom(
                backgroundColor:
                    Colors.blue,
                foregroundColor:
                    Colors.white,
              ),
              onPressed: () {
                Navigator.of(
                  dialogContext,
                ).pop(true);
              },
              child: const Text(
                'To inny lokal',
              ),
            ),
          ],
        );
      },
    );

    return shouldAddAnyway ?? false;
  }

  String _buildReadableAddress(
    Map<String, dynamic> data,
  ) {
    final address =
        data['address']
            as Map<String, dynamic>?;

    if (address == null) {
      return (data['display_name']
                  as String?)
              ?.trim() ??
          '';
    }

    final road =
        (address['road'] ??
                address['pedestrian'] ??
                address['footway'] ??
                address['path'] ??
                address['square'])
            ?.toString();

    final houseNumber =
        address['house_number']
            ?.toString();

    final postcode =
        address['postcode']?.toString();

    final city =
        (address['city'] ??
                address['town'] ??
                address['village'] ??
                address['municipality'])
            ?.toString();

    final streetParts = <String>[
      if (road != null &&
          road.isNotEmpty)
        road,
      if (houseNumber != null &&
          houseNumber.isNotEmpty)
        houseNumber,
    ];

    final cityParts = <String>[
      if (postcode != null &&
          postcode.isNotEmpty)
        postcode,
      if (city != null &&
          city.isNotEmpty)
        city,
    ];

    final readableParts = <String>[
      if (streetParts.isNotEmpty)
        streetParts.join(' '),
      if (cityParts.isNotEmpty)
        cityParts.join(' '),
    ];

    if (readableParts.isNotEmpty) {
      return readableParts.join(', ');
    }

    return (data['display_name']
                as String?)
            ?.trim() ??
        '';
  }

  Future<void> _resolveAddress() async {
    final location =
        _selectedLocation;

    if (location == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            'Najpierw wskaż lokal na mapie.',
          ),
        ),
      );
      return;
    }

    final now = DateTime.now();

    if (_lastAddressRequest != null) {
      final elapsed = now.difference(
        _lastAddressRequest!,
      );

      if (elapsed <
          const Duration(seconds: 1)) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content: Text(
              'Odczekaj chwilę przed kolejnym '
              'sprawdzeniem adresu.',
            ),
          ),
        );
        return;
      }
    }

    _lastAddressRequest = now;

    setState(() {
      _isResolvingAddress = true;
      _resolvedAddress = null;
    });

    final uri = Uri.https(
      'nominatim.openstreetmap.org',
      '/reverse',
      {
        'format': 'jsonv2',
        'lat':
            location.latitude.toString(),
        'lon':
            location.longitude.toString(),
        'addressdetails': '1',
        'accept-language': 'pl',
        'zoom': '18',
        'layer': 'address',
      },
    );

    try {
      final response =
          await http.get(uri);

      if (response.statusCode != 200) {
        throw Exception(
          'Serwer zwrócił kod '
          '${response.statusCode}.',
        );
      }

      final decoded =
          jsonDecode(response.body);

      if (decoded
          is! Map<String, dynamic>) {
        throw const FormatException(
          'Nieprawidłowa odpowiedź serwera.',
        );
      }

      if (decoded['error'] != null) {
        throw Exception(
          decoded['error'].toString(),
        );
      }

      final address =
          _buildReadableAddress(
        decoded,
      );

      if (address.isEmpty) {
        throw Exception(
          'Nie znaleziono adresu dla '
          'wybranego punktu.',
        );
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _resolvedAddress = address;
        _isResolvingAddress = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _resolvedAddress = null;
        _isResolvingAddress = false;
      });

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się pobrać adresu: '
            '$error',
          ),
        ),
      );
    }
  }

  Future<void> _savePlace() async {
    final name =
        _nameController.text.trim();

    final location =
        _selectedLocation;

    final address =
        _resolvedAddress;

    final user =
        FirebaseAuth.instance.currentUser;

    if (user == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            'Nie udało się rozpoznać użytkownika.',
          ),
        ),
      );
      return;
    }

    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            'Podaj nazwę lokalu.',
          ),
        ),
      );
      return;
    }

    if (location == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            'Wskaż lokal na mapie.',
          ),
        ),
      );
      return;
    }

    if (address == null ||
        address.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            'Pobierz adres dla wybranej pinezki.',
          ),
        ),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final shouldContinue =
          await _checkForDuplicates(
        location,
      );

      if (!mounted) {
        return;
      }

      if (!shouldContinue) {
        setState(() {
          _isSaving = false;
        });
        return;
      }

      final firestore =
          FirebaseFirestore.instance;

      final placeReference =
          firestore
              .collection('places')
              .doc();

      final confirmationReference =
          placeReference
              .collection(
                'userConfirmations',
              )
              .doc(user.uid);

      final batch =
          firestore.batch();

      batch.set(
        placeReference,
        {
          'name': name,
          'address': address,
          'location': GeoPoint(
            location.latitude,
            location.longitude,
          ),
          'category': _category,
          'confirmations': 1,

          // NOWE:
          'status': 'pending',

          'createdBy': user.uid,
          'createdAt':
              FieldValue.serverTimestamp(),
          'lastConfirmedAt':
              FieldValue.serverTimestamp(),
        },
      );

      batch.set(
        confirmationReference,
        {
          'userId': user.uid,
          'createdAt':
              FieldValue.serverTimestamp(),
        },
      );

      await batch.commit();

      if (!mounted) {
        return;
      }

      Navigator.of(context).pop();
    } on FirebaseException catch (
        error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isSaving = false;
      });

      final message =
          error.code ==
                  'permission-denied'
              ? 'Operacja została odrzucona przez '
                  'reguły bezpieczeństwa.'
              : 'Nie udało się zapisać lokalu: '
                  '${error.message ?? error.code}';

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(message),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isSaving = false;
      });

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się sprawdzić lub '
            'zapisać lokalu: $error',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasSelectedLocation =
        _selectedLocation != null;

    final hasResolvedAddress =
        _resolvedAddress != null;

    return Scaffold(
      appBar: AppBar(
        title:
            const Text('Dodaj lokal'),
      ),
      body: Column(
        children: [
          Padding(
            padding:
                const EdgeInsets.fromLTRB(
              16,
              16,
              16,
              10,
            ),
            child: Column(
              children: [
                TextField(
                  controller:
                      _nameController,
                  textInputAction:
                      TextInputAction.done,
                  decoration:
                      const InputDecoration(
                    labelText:
                        'Nazwa lokalu',
                    hintText:
                        'Np. Bistro Zielony Talerz',
                    border:
                        OutlineInputBorder(),
                  ),
                ),
                const SizedBox(
                  height: 12,
                ),
                DropdownButtonFormField<
                    String>(
                  initialValue:
                      _category,
                  decoration:
                      const InputDecoration(
                    labelText:
                        'Rodzaj lokalu',
                    border:
                        OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value:
                          'restaurant',
                      child: Text(
                        'Restauracja',
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'cafe',
                      child: Text(
                        'Kawiarnia',
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'bar',
                      child:
                          Text('Bar'),
                    ),
                    DropdownMenuItem(
                      value: 'other',
                      child:
                          Text('Inne'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }

                    setState(() {
                      _category =
                          value;
                    });
                  },
                ),
                const SizedBox(
                  height: 12,
                ),
                Row(
                  crossAxisAlignment:
                      CrossAxisAlignment
                          .start,
                  children: [
                    Icon(
                      hasSelectedLocation
                          ? Icons
                              .location_on
                          : Icons
                              .location_on_outlined,
                      color:
                          hasSelectedLocation
                              ? Colors
                                  .blue
                              : Colors
                                  .grey,
                    ),
                    const SizedBox(
                      width: 8,
                    ),
                    Expanded(
                      child: Text(
                        hasSelectedLocation
                            ? 'Pinezka ustawiona. '
                                'Pobierz adres tego punktu.'
                            : 'Kliknij dokładne miejsce '
                                'lokalu na mapie.',
                      ),
                    ),
                  ],
                ),
                const SizedBox(
                  height: 12,
                ),
                SizedBox(
                  width:
                      double.infinity,
                  child:
                      OutlinedButton
                          .icon(
                    onPressed:
                        hasSelectedLocation &&
                                !_isResolvingAddress
                            ? _resolveAddress
                            : null,
                    icon:
                        _isResolvingAddress
                            ? const SizedBox(
                                width:
                                    18,
                                height:
                                    18,
                                child:
                                    CircularProgressIndicator(
                                  strokeWidth:
                                      2,
                                ),
                              )
                            : const Icon(
                                Icons
                                    .travel_explore,
                              ),
                    label: Text(
                      _isResolvingAddress
                          ? 'Pobieranie adresu...'
                          : hasResolvedAddress
                              ? 'Pobierz adres ponownie'
                              : 'Pobierz adres z pinezki',
                    ),
                  ),
                ),
                if (hasResolvedAddress)
                  ...[
                    const SizedBox(
                      height: 12,
                    ),
                    Container(
                      width:
                          double.infinity,
                      padding:
                          const EdgeInsets
                              .all(12),
                      decoration:
                          BoxDecoration(
                        color: Colors.blue
                            .withValues(
                          alpha: 0.08,
                        ),
                        borderRadius:
                            BorderRadius
                                .circular(
                          12,
                        ),
                        border:
                            Border.all(
                          color: Colors
                              .blue
                              .withValues(
                            alpha:
                                0.25,
                          ),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment:
                            CrossAxisAlignment
                                .start,
                        children: [
                          const Icon(
                            Icons
                                .check_circle,
                            color:
                                Colors.blue,
                          ),
                          const SizedBox(
                            width: 10,
                          ),
                          Expanded(
                            child:
                                Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment
                                      .start,
                              children: [
                                const Text(
                                  'Wykryty adres',
                                  style:
                                      TextStyle(
                                    fontWeight:
                                        FontWeight
                                            .w700,
                                  ),
                                ),
                                const SizedBox(
                                  height:
                                      4,
                                ),
                                Text(
                                  _resolvedAddress!,
                                ),
                                const SizedBox(
                                  height:
                                      4,
                                ),
                                const Text(
                                  'Adres na podstawie danych OpenStreetMap.',
                                  style:
                                      TextStyle(
                                    fontSize:
                                        12,
                                    color:
                                        Colors
                                            .black54,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
              ],
            ),
          ),

          Expanded(
            child: FlutterMap(
              options: MapOptions(
                initialCenter:
                    const LatLng(
                  54.5189,
                  18.5305,
                ),
                initialZoom: 14,
                onTap:
                    (tapPosition,
                        point) {
                  setState(() {
                    _selectedLocation =
                        point;
                    _resolvedAddress =
                        null;
                  });
                },
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://tile.openstreetmap.org/'
                      '{z}/{x}/{y}.png',
                  userAgentPackageName:
                      'pl.freewater.app',
                ),
                if (_selectedLocation !=
                    null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point:
                            _selectedLocation!,
                        width: 50,
                        height: 50,
                        child:
                            const Icon(
                          Icons
                              .water_drop,
                          size: 42,
                          color:
                              Colors.blue,
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
              padding:
                  const EdgeInsets
                      .all(16),
              child: SizedBox(
                width:
                    double.infinity,
                child: FilledButton(
                  style:
                      FilledButton
                          .styleFrom(
                    backgroundColor:
                        Colors.blue,
                    foregroundColor:
                        Colors.white,
                    disabledBackgroundColor:
                        Colors.blue
                            .withValues(
                      alpha: 0.35,
                    ),
                    disabledForegroundColor:
                        Colors.white,
                    padding:
                        const EdgeInsets
                            .symmetric(
                      vertical: 16,
                    ),
                  ),
                  onPressed:
                      _isSaving ||
                              !hasSelectedLocation ||
                              !hasResolvedAddress
                          ? null
                          : _savePlace,
                  child: _isSaving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child:
                              CircularProgressIndicator(
                            strokeWidth:
                                2,
                            color:
                                Colors.white,
                          ),
                        )
                      : const Text(
                          'Dodaj lokal',
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}