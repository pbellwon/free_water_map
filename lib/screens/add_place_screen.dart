import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/nearby_place.dart';

class AddPlaceScreen extends StatefulWidget {
  const AddPlaceScreen({super.key});

  @override
  State<AddPlaceScreen> createState() =>
      _AddPlaceScreenState();
}

class _AddPlaceScreenState extends State<AddPlaceScreen> {
  static const double _duplicateRadiusMeters = 75;

  final _nameController = TextEditingController();
  final Distance _distanceCalculator = const Distance();
  final MapController _mapController = MapController();

  final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(
    region: 'europe-central2',
  );

  LatLng? _selectedLocation;
  String? _resolvedAddress;

  String _category = 'restaurant';

  bool _isResolvingPlace = false;
  bool _isSaving = false;
  bool _nameRecognizedFromMap = false;

  String? _provider;
  String? _providerPlaceId;
  double? _providerDistance;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _moveToUserLocation();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _moveToUserLocation() async {
    try {
      var permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      final position =
          await Geolocator.getCurrentPosition();

      if (!mounted) {
        return;
      }

      _mapController.move(
        LatLng(
          position.latitude,
          position.longitude,
        ),
        16,
      );
    } catch (_) {
      // Fallback pozostaje na Gdyni.
    }
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
                    'W promieniu 75 metrów znaleźliśmy:',
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
                              CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.water_drop,
                              color: Colors.blue,
                              size: 22,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    place.name,
                                    style:
                                        const TextStyle(
                                      fontWeight:
                                          FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    place.address,
                                  ),
                                  const SizedBox(height: 2),
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

  Future<void> _resolvePlace() async {
    final location =
        _selectedLocation;

    if (location == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Najpierw wskaż lokal na mapie.',
          ),
        ),
      );
      return;
    }

    setState(() {
      _isResolvingPlace = true;

      _resolvedAddress = null;
      _nameRecognizedFromMap = false;

      _provider = null;
      _providerPlaceId = null;
      _providerDistance = null;
    });

    try {
      final callable =
          _functions.httpsCallable(
        'recognizePlace',
      );

      final result =
          await callable.call<
              Map<String, dynamic>>(
        {
          'latitude':
              location.latitude,
          'longitude':
              location.longitude,
        },
      );

      if (!mounted) {
        return;
      }

      final data = result.data;

      final nameRaw =
          data['name'];

      final addressRaw =
          data['address'];

      final categoryRaw =
          data['category'];

      final providerRaw =
          data['provider'];

      final providerPlaceIdRaw =
          data['providerPlaceId'];

      final distanceRaw =
          data['distance'];

      final recognizedName =
          nameRaw is String &&
                  nameRaw.trim().isNotEmpty
              ? nameRaw.trim()
              : null;

      final recognizedAddress =
          addressRaw is String &&
                  addressRaw.trim().isNotEmpty
              ? addressRaw.trim()
              : null;

      if (recognizedAddress == null) {
        throw Exception(
          'Nie znaleziono adresu dla wybranego miejsca.',
        );
      }

      String recognizedCategory =
          'other';

      if (categoryRaw is String &&
          [
            'restaurant',
            'cafe',
            'bar',
            'other',
          ].contains(categoryRaw)) {
        recognizedCategory =
            categoryRaw;
      }

      final recognizedProvider =
          providerRaw is String
              ? providerRaw
              : null;

      final recognizedProviderPlaceId =
          providerPlaceIdRaw is String
              ? providerPlaceIdRaw
              : null;

      final recognizedDistance =
          distanceRaw is num
              ? distanceRaw.toDouble()
              : null;

      setState(() {
        _resolvedAddress =
            recognizedAddress;

        _category =
            recognizedCategory;

        _provider =
            recognizedProvider;

        _providerPlaceId =
            recognizedProviderPlaceId;

        _providerDistance =
            recognizedDistance;

        if (recognizedName != null) {
          _nameController.text =
              recognizedName;

          _nameRecognizedFromMap =
              true;
        }

        _isResolvingPlace =
            false;
      });
    } on FirebaseFunctionsException catch (
        error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isResolvingPlace =
            false;
      });

      String message;

      switch (error.code) {
        case 'invalid-argument':
          message =
              error.message ??
                  'Nieprawidłowe współrzędne.';
          break;

        case 'unauthenticated':
          message =
              'Nie udało się rozpoznać użytkownika. '
              'Odśwież aplikację i spróbuj ponownie.';
          break;

        case 'permission-denied':
          message =
              'Ta operacja nie jest obecnie dozwolona.';
          break;

        case 'failed-precondition':
          message =
              'Nie udało się zweryfikować aplikacji. '
              'Odśwież stronę i spróbuj ponownie.';
          break;

        case 'internal':
          message =
              error.message ??
                  'Nie udało się rozpoznać lokalu.';
          break;

        default:
          message =
              error.message ??
                  'Nie udało się rozpoznać lokalu.';
      }

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
        _isResolvingPlace =
            false;
      });

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się rozpoznać lokalu: '
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
            'Najpierw rozpoznaj lokal z pinezki.',
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

      final callable =
          _functions.httpsCallable(
        'createPlace',
      );

      final data = <String, dynamic>{
        'name': name,
        'address': address,
        'latitude':
            location.latitude,
        'longitude':
            location.longitude,
        'category':
            _category,
      };

      if (_provider != null) {
        data['provider'] =
            _provider;
      }

      if (_providerPlaceId != null) {
        data['providerPlaceId'] =
            _providerPlaceId;
      }

      if (_providerDistance != null) {
        data['providerDistance'] =
            _providerDistance;
      }

      final result =
          await callable.call<
              Map<String, dynamic>>(
        data,
      );

      if (!mounted) {
        return;
      }

      final remainingRaw =
          result.data['remaining'];

      final remaining =
          remainingRaw is num
              ? remainingRaw.toInt()
              : null;

      if (remaining != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          SnackBar(
            content: Text(
              remaining == 0
                  ? 'Lokal dodany. Wykorzystałeś limit '
                      '2 lokali na najbliższe 24 godziny.'
                  : 'Lokal dodany. Możesz dodać jeszcze '
                      '$remaining lokal w ciągu 24 godzin.',
            ),
          ),
        );
      }

      Navigator.of(context).pop();
    } on FirebaseFunctionsException catch (
        error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isSaving = false;
      });

      String message;

      switch (error.code) {
        case 'resource-exhausted':
          message =
              'Osiągnąłeś limit 2 nowych lokali '
              'w ciągu 24 godzin.';
          break;

        case 'unauthenticated':
          message =
              'Nie udało się rozpoznać użytkownika. '
              'Odśwież aplikację i spróbuj ponownie.';
          break;

        case 'failed-precondition':
          message =
              'Nie udało się zweryfikować aplikacji. '
              'Odśwież stronę i spróbuj ponownie.';
          break;

        case 'permission-denied':
          message =
              'Ta operacja nie jest obecnie dozwolona.';
          break;

        case 'invalid-argument':
          message =
              error.message ??
                  'Nieprawidłowe dane lokalu.';
          break;

        default:
          message =
              error.message ??
                  'Nie udało się dodać lokalu.';
      }

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
            'Nie udało się dodać lokalu: '
            '$error',
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
                  onChanged: (_) {
                    if (_nameRecognizedFromMap) {
                      setState(() {
                        _nameRecognizedFromMap =
                            false;
                      });
                    }
                  },
                  decoration:
                      InputDecoration(
                    labelText:
                        'Nazwa lokalu',
                    hintText:
                        'Najpierw spróbuj rozpoznać lokal',
                    border:
                        const OutlineInputBorder(),
                    suffixIcon:
                        _nameRecognizedFromMap
                            ? const Icon(
                                Icons
                                    .verified_outlined,
                                color:
                                    Colors.blue,
                              )
                            : null,
                  ),
                ),

                if (_nameRecognizedFromMap) ...[
                  const SizedBox(height: 6),
                  const Align(
                    alignment:
                        Alignment.centerLeft,
                    child: Row(
                      children: [
                        Icon(
                          Icons.check_circle,
                          size: 16,
                          color: Colors.blue,
                        ),
                        SizedBox(width: 6),
                        Text(
                          'Nazwa znaleziona na mapie',
                          style: TextStyle(
                            color: Colors.blue,
                            fontSize: 12,
                            fontWeight:
                                FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                if (hasResolvedAddress &&
                    !_nameRecognizedFromMap &&
                    _nameController.text
                        .trim()
                        .isEmpty) ...[
                  const SizedBox(height: 6),
                  const Align(
                    alignment:
                        Alignment.centerLeft,
                    child: Text(
                      'Nie znaleźliśmy nazwy lokalu na mapie. '
                      'Wpisz ją ręcznie.',
                      style: TextStyle(
                        color: Colors.black54,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 12),

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

                const SizedBox(height: 12),

                Row(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Icon(
                      hasSelectedLocation
                          ? Icons.location_on
                          : Icons
                              .location_on_outlined,
                      color:
                          hasSelectedLocation
                              ? Colors.blue
                              : Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        hasSelectedLocation
                            ? 'Pinezka ustawiona. '
                                'Spróbuj rozpoznać lokal.'
                            : 'Kliknij dokładne miejsce '
                                'lokalu na mapie.',
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                SizedBox(
                  width: double.infinity,
                  child:
                      OutlinedButton.icon(
                    onPressed:
                        hasSelectedLocation &&
                                !_isResolvingPlace
                            ? _resolvePlace
                            : null,
                    icon:
                        _isResolvingPlace
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(
                                Icons
                                    .travel_explore,
                              ),
                    label: Text(
                      _isResolvingPlace
                          ? 'Rozpoznaję lokal...'
                          : hasResolvedAddress
                              ? 'Rozpoznaj ponownie'
                              : 'Rozpoznaj lokal',
                    ),
                  ),
                ),

                if (hasResolvedAddress) ...[
                  const SizedBox(height: 12),

                  Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.all(
                      12,
                    ),
                    decoration: BoxDecoration(
                      color:
                          Colors.blue.withValues(
                        alpha: 0.08,
                      ),
                      borderRadius:
                          BorderRadius.circular(
                        12,
                      ),
                      border: Border.all(
                        color:
                            Colors.blue.withValues(
                          alpha: 0.25,
                        ),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.check_circle,
                          color: Colors.blue,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment
                                    .start,
                            children: [
                              const Text(
                                'Wykryty adres',
                                style: TextStyle(
                                  fontWeight:
                                      FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _resolvedAddress!,
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Dane lokalizacyjne: Geoapify / OpenStreetMap.',
                                style: TextStyle(
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
                  ),
                ],
              ],
            ),
          ),

          Expanded(
            child: FlutterMap(
              mapController:
                  _mapController,
              options: MapOptions(
                initialCenter:
                    const LatLng(
                  54.5189,
                  18.5305,
                ),
                initialZoom: 14,
                interactionOptions:
                    const InteractionOptions(
                  flags:
                      InteractiveFlag.drag |
                      InteractiveFlag
                          .pinchZoom |
                      InteractiveFlag
                          .doubleTapZoom |
                      InteractiveFlag
                          .scrollWheelZoom,
                ),
                onTap:
                    (tapPosition,
                        point) {
                  setState(() {
                    _selectedLocation =
                        point;

                    _nameController.clear();

                    _resolvedAddress =
                        null;

                    _nameRecognizedFromMap =
                        false;

                    _provider = null;
                    _providerPlaceId = null;
                    _providerDistance = null;
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
                          Icons.water_drop,
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
                  const EdgeInsets.all(
                16,
              ),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style:
                      FilledButton.styleFrom(
                    backgroundColor:
                        Colors.blue,
                    foregroundColor:
                        Colors.white,
                    disabledBackgroundColor:
                        Colors.blue.withValues(
                      alpha: 0.35,
                    ),
                    disabledForegroundColor:
                        Colors.white,
                    padding:
                        const EdgeInsets.symmetric(
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
                            strokeWidth: 2,
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