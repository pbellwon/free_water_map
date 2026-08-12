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

  final Distance _distanceCalculator =
      const Distance();

  final MapController _mapController =
      MapController();

  final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(
    region: 'europe-central2',
  );

  LatLng? _selectedLocation;
  String? _resolvedAddress;

  String _category = 'restaurant';

  bool _isResolvingPlace = false;
  bool _isSaving = false;

  bool _placeWasResolved = false;


  String? _provider;
  String? _providerPlaceId;
  double? _providerDistance;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance
        .addPostFrameCallback(
      (_) {
        _moveToUserLocation();
      },
    );
  }

  @override
  void dispose() {
    _nameController.dispose();

    super.dispose();
  }

  Future<void> _moveToUserLocation() async {
    try {
      var permission =
          await Geolocator.checkPermission();

      if (permission ==
          LocationPermission.denied) {
        permission =
            await Geolocator.requestPermission();
      }

      if (permission ==
              LocationPermission.denied ||
          permission ==
              LocationPermission.deniedForever) {
        return;
      }

      final position =
          await Geolocator.getCurrentPosition();

      if (!mounted) {
        return;
      }

      // BYŁO 16.
      // Teraz użytkownik widzi większy fragment okolicy.
      _mapController.move(
        LatLng(
          position.latitude,
          position.longitude,
        ),
        14,
      );
    } catch (_) {
      // Fallback pozostaje na Gdyni.
    }
  }

  void _selectLocation(
    LatLng point,
  ) {
    setState(() {
      _selectedLocation =
          point;

      _placeWasResolved =
          false;

      _nameController.clear();

      _resolvedAddress =
          null;

      _category =
          'restaurant';


      _provider =
          null;

      _providerPlaceId =
          null;

      _providerDistance =
          null;
    });
  }

  Future<List<NearbyPlace>>
      _findNearbyPlaces(
    LatLng selectedLocation,
  ) async {
    final snapshot =
        await FirebaseFirestore.instance
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

    final nearbyPlaces =
        <NearbyPlace>[];

    for (final document
        in snapshot.docs) {
      final data =
          document.data();

      final location =
          data['location']
              as GeoPoint?;

      if (location == null) {
        continue;
      }

      final placeLocation =
          LatLng(
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
                data['address']
                        as String? ??
                    'Brak adresu',
            distanceMeters:
                distanceMeters,
          ),
        );
      }
    }

    nearbyPlaces.sort(
      (
        first,
        second,
      ) =>
          first.distanceMeters
              .compareTo(
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
            constraints:
                const BoxConstraints(
              maxWidth: 460,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize:
                    MainAxisSize.min,
                crossAxisAlignment:
                    CrossAxisAlignment
                        .start,
                children: [
                  const Text(
                    'W promieniu 75 metrów znaleźliśmy:',
                  ),

                  const SizedBox(
                    height: 14,
                  ),

                  ...nearbyPlaces
                      .take(3)
                      .map(
                    (place) {
                      return Padding(
                        padding:
                            const EdgeInsets
                                .only(
                          bottom: 12,
                        ),
                        child: Row(
                          crossAxisAlignment:
                              CrossAxisAlignment
                                  .start,
                          children: [
                            const Icon(
                              Icons
                                  .water_drop,
                              color:
                                  Colors.blue,
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
                                      fontSize:
                                          12,
                                      color: Colors
                                          .black54,
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

    return shouldAddAnyway ??
        false;
  }

  Future<void> _resolvePlace() async {
    final location =
        _selectedLocation;

    if (location == null) {
      return;
    }

    setState(() {
      _isResolvingPlace = true;

      _placeWasResolved = false;

      _nameController.clear();

      _resolvedAddress = null;

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

      final data =
          result.data;

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
                  nameRaw
                      .trim()
                      .isNotEmpty
              ? nameRaw.trim()
              : null;

      final recognizedAddress =
          addressRaw is String &&
                  addressRaw
                      .trim()
                      .isNotEmpty
              ? addressRaw.trim()
              : null;

      if (recognizedAddress ==
          null) {
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
          ].contains(
            categoryRaw,
          )) {
        recognizedCategory =
            categoryRaw;
      }

      final recognizedProvider =
          providerRaw is String
              ? providerRaw
              : null;

      final recognizedProviderPlaceId =
          providerPlaceIdRaw
                  is String
              ? providerPlaceIdRaw
              : null;

      final recognizedDistance =
          distanceRaw is num
              ? distanceRaw
                  .toDouble()
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

        if (recognizedName !=
            null) {
          _nameController.text =
              recognizedName;
        }

        _placeWasResolved =
            true;

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

        default:
          message =
              error.message ??
              'Nie udało się rozpoznać lokalu.';
      }

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content:
              Text(message),
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
            'Nie udało się rozpoznać lokalu: $error',
          ),
        ),
      );
    }
  }

  Future<void> _savePlace() async {
    final name =
        _nameController.text
            .trim();

    final location =
        _selectedLocation;

    final address =
        _resolvedAddress;

    if (!_placeWasResolved) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            'Najpierw wyszukaj lokal.',
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
      return;
    }

    if (address == null ||
        address.isEmpty) {
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

      final data =
          <String, dynamic>{
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

      if (_providerPlaceId !=
          null) {
        data['providerPlaceId'] =
            _providerPlaceId;
      }

      if (_providerDistance !=
          null) {
        data['providerDistance'] =
            _providerDistance;
      }

      await callable.call<
          Map<String, dynamic>>(
        data,
      );

      if (!mounted) {
        return;
      }

      Navigator.of(context)
          .pop(true);
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
          content:
              Text(message),
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
            'Nie udało się dodać lokalu: $error',
          ),
        ),
      );
    }
  }

  Widget _buildStepHeader({
    required String number,
    required String title,
    required String subtitle,
  }) {
    return Row(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          alignment:
              Alignment.center,
          decoration:
              const BoxDecoration(
            color: Colors.blue,
            shape: BoxShape.circle,
          ),
          child: Text(
            number,
            style:
                const TextStyle(
              color: Colors.white,
              fontWeight:
                  FontWeight.w800,
            ),
          ),
        ),

        const SizedBox(width: 10),

        Expanded(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style:
                    const TextStyle(
                  fontSize: 17,
                  fontWeight:
                      FontWeight.w700,
                ),
              ),

              const SizedBox(height: 3),

              Text(
                subtitle,
                style:
                    const TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color:
                      Colors.black54,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    final hasSelectedLocation =
        _selectedLocation !=
            null;

    final canSearch =
        hasSelectedLocation &&
        !_isResolvingPlace &&
        !_isSaving;

    final formEnabled =
        _placeWasResolved &&
        !_isResolvingPlace &&
        !_isSaving;

    final canAdd =
        formEnabled &&
        _resolvedAddress !=
            null &&
        _nameController.text
            .trim()
            .isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title:
            const Text(
          'Dodaj lokal',
        ),
      ),
      body: SafeArea(
        top: false,
        child:
            SingleChildScrollView(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment
                    .stretch,
            children: [
              Padding(
                padding:
                    const EdgeInsets
                        .fromLTRB(
                  16,
                  18,
                  16,
                  12,
                ),
                child:
                    _buildStepHeader(
                  number: '1',
                  title:
                      'Wskaż lokal na mapie',
                  subtitle:
                      'Dotknij dokładnego miejsca restauracji, '
                      'kawiarni lub baru.',
                ),
              ),

              SizedBox(
                height: 330,
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController:
                          _mapController,
                      options:
                          MapOptions(
                        initialCenter:
                            const LatLng(
                          54.5189,
                          18.5305,
                        ),

                        // BYŁO 14.
                        initialZoom:
                            13,

                        interactionOptions:
                            const InteractionOptions(
                          flags:
                              InteractiveFlag.drag |
                              InteractiveFlag.pinchZoom |
                              InteractiveFlag.doubleTapZoom |
                              InteractiveFlag.scrollWheelZoom,
                        ),

                        onTap: (
                          tapPosition,
                          point,
                        ) {
                          _selectLocation(
                            point,
                          );
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
                                width:
                                    50,
                                height:
                                    50,
                                child:
                                    Icon(
                                  Icons
                                      .water_drop,
                                  size:
                                      42,
                                  color:
                                      Colors.blue.shade700,
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

                    Positioned(
                      left: 16,
                      right: 16,
                      top: 14,
                      child:
                          IgnorePointer(
                        child:
                            Container(
                          padding:
                              const EdgeInsets.symmetric(
                            horizontal:
                                14,
                            vertical:
                                10,
                          ),
                          decoration:
                              BoxDecoration(
                            color:
                                Colors.white.withValues(
                              alpha:
                                  0.92,
                            ),
                            borderRadius:
                                BorderRadius.circular(
                              12,
                            ),
                            boxShadow:
                                const [
                              BoxShadow(
                                blurRadius:
                                    8,
                                color: Colors
                                    .black12,
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Icon(
                                hasSelectedLocation
                                    ? Icons.check_circle
                                    : Icons.touch_app_outlined,
                                color:
                                    Colors.blue,
                                size:
                                    20,
                              ),

                              const SizedBox(
                                width:
                                    8,
                              ),

                              Expanded(
                                child:
                                    Text(
                                  hasSelectedLocation
                                      ? 'Pinezka ustawiona. Możesz teraz wyszukać lokal.'
                                      : 'Dotknij mapy, aby ustawić pinezkę.',
                                  style:
                                      const TextStyle(
                                    fontWeight:
                                        FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              Padding(
                padding:
                    const EdgeInsets
                        .fromLTRB(
                  16,
                  14,
                  16,
                  20,
                ),
                child: SizedBox(
                  width:
                      double.infinity,
                  child:
                      FilledButton.icon(
                    onPressed:
                        canSearch
                            ? _resolvePlace
                            : null,
                    icon:
                        _isResolvingPlace
                            ? const SizedBox(
                                width:
                                    20,
                                height:
                                    20,
                                child:
                                    CircularProgressIndicator(
                                  strokeWidth:
                                      2,
                                  color:
                                      Colors.white,
                                ),
                              )
                            : const Icon(
                                Icons.search,
                              ),
                    label: Text(
                      _isResolvingPlace
                          ? 'Wyszukuję lokal...'
                          : _placeWasResolved
                              ? 'Wyszukaj ponownie'
                              : 'Wyszukaj lokal',
                    ),
                  ),
                ),
              ),

              const Divider(
                height: 1,
              ),

              Padding(
                padding:
                    const EdgeInsets
                        .fromLTRB(
                  16,
                  20,
                  16,
                  12,
                ),
                child:
                    _buildStepHeader(
                  number: '2',
                  title:
                      'Sprawdź dane lokalu',
                  subtitle:
                      'Po wyszukaniu sprawdź nazwę, '
                      'rodzaj lokalu i adres.',
                ),
              ),

              Padding(
                padding:
                    const EdgeInsets
                        .fromLTRB(
                  16,
                  6,
                  16,
                  16,
                ),
                child: Column(
                  children: [
                    TextField(
                      controller:
                          _nameController,
                      enabled:
                          formEnabled,
                      onChanged: (_) {
                        setState(() {
                        });
                      },
                      decoration:
                          InputDecoration(
                        labelText:
                            'Nazwa lokalu',
                        hintText:
                            formEnabled
                                ? 'Nazwa lokalu'
                                : 'Najpierw wyszukaj lokal',
                        border:
                            const OutlineInputBorder(),
                      ),
                    ),

                    const SizedBox(
                      height: 14,
                    ),

                    DropdownButtonFormField<
                        String>(
                      value:
                          _category,
                      decoration:
                          const InputDecoration(
                        labelText:
                            'Rodzaj lokalu',
                        border:
                            OutlineInputBorder(),
                      ),
                      items:
                          const [
                        DropdownMenuItem(
                          value:
                              'restaurant',
                          child:
                              Text(
                            'Restauracja',
                          ),
                        ),
                        DropdownMenuItem(
                          value:
                              'cafe',
                          child:
                              Text(
                            'Kawiarnia',
                          ),
                        ),
                        DropdownMenuItem(
                          value:
                              'bar',
                          child:
                              Text(
                            'Bar',
                          ),
                        ),
                        DropdownMenuItem(
                          value:
                              'other',
                          child:
                              Text(
                            'Inne',
                          ),
                        ),
                      ],
                      onChanged:
                          formEnabled
                              ? (value) {
                                  if (value ==
                                      null) {
                                    return;
                                  }

                                  setState(
                                    () {
                                      _category =
                                          value;
                                    },
                                  );
                                }
                              : null,
                    ),

                    const SizedBox(
                      height: 14,
                    ),

                    Container(
                      width:
                          double.infinity,
                      padding:
                          const EdgeInsets
                              .all(
                        14,
                      ),
                      decoration:
                          BoxDecoration(
                        color:
                            formEnabled
                                ? Colors.blue.withValues(
                                    alpha:
                                        0.07,
                                  )
                                : Colors.grey.shade100,
                        borderRadius:
                            BorderRadius.circular(
                          12,
                        ),
                      ),
                      child: Text(
                        _resolvedAddress ??
                            'Najpierw wyszukaj lokal',
                      ),
                    ),

                    const SizedBox(
                      height: 22,
                    ),

                    SizedBox(
                      width:
                          double.infinity,
                      child:
                          FilledButton(
                        onPressed:
                            _isSaving ||
                                    !canAdd
                                ? null
                                : _savePlace,
                        child:
                            _isSaving
                                ? const SizedBox(
                                    width:
                                        22,
                                    height:
                                        22,
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
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}