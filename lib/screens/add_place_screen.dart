import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/nearby_place.dart';
import '../widgets/location_search_dialog.dart';

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

  Future<void> _openLocationSearch() async {
    final result =
        await showDialog<
            LocationSearchResult>(
      context: context,
      builder: (context) {
        return LocationSearchDialog(
          functions: _functions,
        );
      },
    );

    if (result == null ||
        !mounted) {
      return;
    }

    final point =
        LatLng(
      result.latitude,
      result.longitude,
    );

    _mapController.move(
      point,
      result.preferredZoom,
    );

    _selectLocation(
      point,
    );

    await Future.delayed(
      const Duration(
        milliseconds: 150,
      ),
    );

    if (!mounted) {
      return;
    }

    await _resolvePlace();
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
                              Icons.water_drop,
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
  // ==================================================================
  // BUILD
  // ==================================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    final hasSelectedLocation =
        _selectedLocation != null;

    final formEnabled =
        _placeWasResolved &&
        !_isResolvingPlace &&
        !_isSaving;

    final canAdd =
        formEnabled &&
        _resolvedAddress != null &&
        _nameController.text
            .trim()
            .isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Dodaj lokal',
        ),
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (
            context,
            constraints,
          ) {
            final isWide =
                constraints.maxWidth >=
                    700;

            final mapHeight =
                isWide
                    ? 290.0
                    : 245.0;

            return SingleChildScrollView(
              padding:
                  EdgeInsets.fromLTRB(
                isWide ? 24 : 16,
                18,
                isWide ? 24 : 16,
                32,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(
                    maxWidth: 720,
                  ),
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment
                            .stretch,
                    children: [
                      // ==================================================
                      // INTRO
                      // ==================================================

                      const Text(
                        'Dodaj miejsce z darmową kranówką',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight:
                              FontWeight.w800,
                          height: 1.2,
                        ),
                      ),

                      const SizedBox(
                        height: 8,
                      ),

                      const Text(
                        'Znajdź lokal lub adres, a następnie sprawdź '
                        'pozycję pinezki i dane miejsca.',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.45,
                          color:
                              Colors.black54,
                        ),
                      ),

                      const SizedBox(
                        height: 22,
                      ),

                      // ==================================================
                      // SEARCH
                      // ==================================================

                      Material(
                        color:
                            Colors.white,
                        elevation: 1,
                        borderRadius:
                            BorderRadius.circular(
                          14,
                        ),
                        child: InkWell(
                          borderRadius:
                              BorderRadius.circular(
                            14,
                          ),
                          onTap:
                              _isSaving ||
                                      _isResolvingPlace
                                  ? null
                                  : _openLocationSearch,
                          child: Container(
                            padding:
                                const EdgeInsets
                                    .symmetric(
                              horizontal: 16,
                              vertical: 15,
                            ),
                            decoration:
                                BoxDecoration(
                              borderRadius:
                                  BorderRadius
                                      .circular(
                                14,
                              ),
                              border:
                                  Border.all(
                                color: Colors
                                    .grey
                                    .shade300,
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.search,
                                  color:
                                      Colors.blue,
                                ),

                                const SizedBox(
                                  width: 12,
                                ),

                                const Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment
                                            .start,
                                    children: [
                                      Text(
                                        'Znajdź miejsce lub adres',
                                        style:
                                            TextStyle(
                                          fontWeight:
                                              FontWeight
                                                  .w700,
                                          fontSize:
                                              15,
                                        ),
                                      ),

                                      SizedBox(
                                        height: 2,
                                      ),

                                      Text(
                                        'np. Rynek, Wrocław lub Świętojańska 10, Gdynia',
                                        maxLines: 1,
                                        overflow:
                                            TextOverflow
                                                .ellipsis,
                                        style:
                                            TextStyle(
                                          fontSize:
                                              12.5,
                                          color:
                                              Colors
                                                  .black54,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                const SizedBox(
                                  width: 8,
                                ),

                                const Icon(
                                  Icons
                                      .chevron_right,
                                  color:
                                      Colors.black45,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(
                        height: 18,
                      ),

                      // ==================================================
                      // MAP
                      // ==================================================

                      ClipRRect(
                        borderRadius:
                            BorderRadius.circular(
                          16,
                        ),
                        child: SizedBox(
                          height:
                              mapHeight,
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
                                  initialZoom:
                                      13,
                                  interactionOptions:
                                      const InteractionOptions(
                                    flags:
                                        InteractiveFlag
                                                .drag |
                                            InteractiveFlag
                                                .pinchZoom |
                                            InteractiveFlag
                                                .doubleTapZoom |
                                            InteractiveFlag
                                                .scrollWheelZoom,
                                  ),
                                  onTap: (
                                    tapPosition,
                                    point,
                                  ) {
                                    if (_isSaving ||
                                        _isResolvingPlace) {
                                      return;
                                    }

                                    _selectLocation(
                                      point,
                                    );

                                    _resolvePlace();
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
                                            color: Colors
                                                .blue
                                                .shade700,
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

                              // ------------------------------------------
                              // MAP INFO
                              // ------------------------------------------

                              Positioned(
                                left: 12,
                                right: 12,
                                top: 12,
                                child: IgnorePointer(
                                  child:
                                      Container(
                                    padding:
                                        const EdgeInsets
                                            .symmetric(
                                      horizontal:
                                          12,
                                      vertical:
                                          9,
                                    ),
                                    decoration:
                                        BoxDecoration(
                                      color: Colors
                                          .white
                                          .withValues(
                                        alpha:
                                            0.93,
                                      ),
                                      borderRadius:
                                          BorderRadius
                                              .circular(
                                        10,
                                      ),
                                      boxShadow:
                                          const [
                                        BoxShadow(
                                          blurRadius:
                                              8,
                                          color:
                                              Colors
                                                  .black12,
                                        ),
                                      ],
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          hasSelectedLocation
                                              ? Icons
                                                  .location_on
                                              : Icons
                                                  .touch_app_outlined,
                                          size:
                                              19,
                                          color:
                                              Colors.blue,
                                        ),

                                        const SizedBox(
                                          width:
                                              8,
                                        ),

                                        Expanded(
                                          child:
                                              Text(
                                            hasSelectedLocation
                                                ? 'Dotknij mapy, jeśli chcesz poprawić pozycję pinezki.'
                                                : 'Dotknij mapy, aby ustawić pinezkę ręcznie.',
                                            style:
                                                const TextStyle(
                                              fontSize:
                                                  12.5,
                                              fontWeight:
                                                  FontWeight
                                                      .w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),

                              // ------------------------------------------
                              // LOCATION BUTTON
                              // ------------------------------------------

                              Positioned(
                                right: 12,
                                bottom: 28,
                                child:
                                    Material(
                                  color:
                                      Colors.white,
                                  elevation:
                                      3,
                                  shape:
                                      const CircleBorder(),
                                  child:
                                      IconButton(
                                    tooltip:
                                        'Moja lokalizacja',
                                    onPressed:
                                        _isSaving ||
                                                _isResolvingPlace
                                            ? null
                                            : _moveToUserLocation,
                                    icon:
                                        const Icon(
                                      Icons
                                          .my_location,
                                      color:
                                          Colors.blue,
                                    ),
                                  ),
                                ),
                              ),

                              // ------------------------------------------
                              // RESOLVING OVERLAY
                              // ------------------------------------------

                              if (_isResolvingPlace)
                                Positioned.fill(
                                  child:
                                      Container(
                                    color: Colors
                                        .white
                                        .withValues(
                                      alpha:
                                          0.72,
                                    ),
                                    alignment:
                                        Alignment
                                            .center,
                                    child:
                                        const Column(
                                      mainAxisSize:
                                          MainAxisSize
                                              .min,
                                      children: [
                                        CircularProgressIndicator(),
                                        SizedBox(
                                          height:
                                              12,
                                        ),
                                        Text(
                                          'Rozpoznaję lokal...',
                                          style:
                                              TextStyle(
                                            fontWeight:
                                                FontWeight
                                                    .w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),

                      // ==================================================
                      // SMALL LOCATION STATE
                      // ==================================================

                      if (hasSelectedLocation &&
                          !_placeWasResolved &&
                          !_isResolvingPlace) ...[
                        const SizedBox(
                          height: 12,
                        ),

                        Container(
                          padding:
                              const EdgeInsets
                                  .all(
                            12,
                          ),
                          decoration:
                              BoxDecoration(
                            color: Colors
                                .orange
                                .withValues(
                              alpha:
                                  0.07,
                            ),
                            borderRadius:
                                BorderRadius
                                    .circular(
                              12,
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons
                                    .info_outline,
                                size:
                                    20,
                                color:
                                    Colors.orange,
                              ),

                              const SizedBox(
                                width:
                                    10,
                              ),

                              const Expanded(
                                child:
                                    Text(
                                  'Nie udało się jeszcze uzupełnić danych tego miejsca.',
                                  style:
                                      TextStyle(
                                    fontSize:
                                        13,
                                  ),
                                ),
                              ),

                              TextButton(
                                onPressed:
                                    _resolvePlace,
                                child:
                                    const Text(
                                  'Spróbuj ponownie',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      // ==================================================
                      // PLACE DETAILS
                      // ==================================================

                      if (_placeWasResolved) ...[
                        const SizedBox(
                          height: 24,
                        ),

                        Row(
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration:
                                  BoxDecoration(
                                color: Colors
                                    .blue
                                    .withValues(
                                  alpha:
                                      0.10,
                                ),
                                shape:
                                    BoxShape
                                        .circle,
                              ),
                              child:
                                  const Icon(
                                Icons
                                    .storefront_outlined,
                                color:
                                    Colors.blue,
                                size:
                                    19,
                              ),
                            ),

                            const SizedBox(
                              width: 10,
                            ),

                            const Expanded(
                              child: Text(
                                'Sprawdź dane',
                                style:
                                    TextStyle(
                                  fontSize:
                                      18,
                                  fontWeight:
                                      FontWeight
                                          .w700,
                                ),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(
                          height: 14,
                        ),

                        Container(
                          padding:
                              EdgeInsets.all(
                            isWide
                                ? 20
                                : 16,
                          ),
                          decoration:
                              BoxDecoration(
                            color:
                                Colors.white,
                            borderRadius:
                                BorderRadius
                                    .circular(
                              16,
                            ),
                            border:
                                Border.all(
                              color: Colors
                                  .grey
                                  .shade200,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment
                                    .stretch,
                            children: [
                              TextField(
                                controller:
                                    _nameController,
                                enabled:
                                    formEnabled,
                                onChanged:
                                    (_) {
                                  setState(
                                    () {},
                                  );
                                },
                                decoration:
                                    InputDecoration(
                                  labelText:
                                      'Nazwa lokalu',
                                  prefixIcon:
                                      const Icon(
                                    Icons
                                        .storefront_outlined,
                                  ),
                                  border:
                                      OutlineInputBorder(
                                    borderRadius:
                                        BorderRadius
                                            .circular(
                                      12,
                                    ),
                                  ),
                                ),
                              ),

                              const SizedBox(
                                height:
                                    14,
                              ),

                              DropdownButtonFormField<
                                  String>(
                                initialValue:
                                    _category,
                                decoration:
                                    InputDecoration(
                                  labelText:
                                      'Rodzaj lokalu',
                                  prefixIcon:
                                      const Icon(
                                    Icons
                                        .category_outlined,
                                  ),
                                  border:
                                      OutlineInputBorder(
                                    borderRadius:
                                        BorderRadius
                                            .circular(
                                      12,
                                    ),
                                  ),
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
                                        ? (
                                            value,
                                          ) {
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

                              if (_resolvedAddress !=
                                  null) ...[
                                const SizedBox(
                                  height:
                                      16,
                                ),

                                Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment
                                          .start,
                                  children: [
                                    const Padding(
                                      padding:
                                          EdgeInsets
                                              .only(
                                        top:
                                            1,
                                      ),
                                      child:
                                          Icon(
                                        Icons
                                            .location_on_outlined,
                                        color:
                                            Colors.blue,
                                        size:
                                            21,
                                      ),
                                    ),

                                    const SizedBox(
                                      width:
                                          9,
                                    ),

                                    Expanded(
                                      child:
                                          Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment
                                                .start,
                                        children: [
                                          const Text(
                                            'Adres',
                                            style:
                                                TextStyle(
                                              fontSize:
                                                  12,
                                              color:
                                                  Colors.black54,
                                              fontWeight:
                                                  FontWeight.w600,
                                            ),
                                          ),

                                          const SizedBox(
                                            height:
                                                2,
                                          ),

                                          Text(
                                            _resolvedAddress!,
                                            style:
                                                const TextStyle(
                                              fontSize:
                                                  14,
                                              height:
                                                  1.35,
                                              fontWeight:
                                                  FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),

                        const SizedBox(
                          height: 22,
                        ),

                        SizedBox(
                          width:
                              double.infinity,
                          child:
                              FilledButton.icon(
                            style:
                                FilledButton
                                    .styleFrom(
                              backgroundColor:
                                  Colors.blue,
                              foregroundColor:
                                  Colors.white,
                              padding:
                                  const EdgeInsets
                                      .symmetric(
                                vertical:
                                    15,
                              ),
                            ),
                            onPressed:
                                _isSaving ||
                                        !canAdd
                                    ? null
                                    : _savePlace,
                            icon:
                                _isSaving
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
                                        Icons
                                            .add_location_alt_outlined,
                                      ),
                            label: Text(
                              _isSaving
                                  ? 'Dodaję lokal...'
                                  : 'Dodaj lokal',
                              style:
                                  const TextStyle(
                                fontWeight:
                                    FontWeight
                                        .w700,
                              ),
                            ),
                          ),
                        ),
                      ],

                      // ==================================================
                      // EMPTY STATE
                      // ==================================================

                      if (!_placeWasResolved &&
                          !hasSelectedLocation &&
                          !_isResolvingPlace) ...[
                        const SizedBox(
                          height: 18,
                        ),

                        const Center(
                          child: Text(
                            'Najpierw wyszukaj miejsce lub wskaż je na mapie.',
                            textAlign:
                                TextAlign
                                    .center,
                            style:
                                TextStyle(
                              fontSize:
                                  13,
                              color:
                                  Colors.black45,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}