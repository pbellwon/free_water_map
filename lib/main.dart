import 'dart:async';
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'app/free_water_app.dart';
import 'firebase_options.dart';
import 'models/place_report_data.dart';
import 'screens/add_place_screen.dart';
import 'services/authentication_service.dart';
import 'widgets/report_problem_sheet.dart';
import 'widgets/location_search_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  await FirebaseAppCheck.instance.activate(
    providerWeb: ReCaptchaEnterpriseProvider(
      '6LcV9XctAAAAAPq6-9vgUa0MilY_scUZZ-_OW2aA',
    ),
  );

  await AuthenticationService.ensureAnonymousUser();

  runApp(const FreeWaterApp());
}

// ==================================================================
// VIEWPORT CACHE
// ==================================================================

class _ViewportCacheEntry {
  final double south;
  final double north;
  final double west;
  final double east;

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> places;

  final DateTime createdAt;

  const _ViewportCacheEntry({
    required this.south,
    required this.north,
    required this.west,
    required this.east,
    required this.places,
    required this.createdAt,
  });

  bool containsBounds({
    required double requestedSouth,
    required double requestedNorth,
    required double requestedWest,
    required double requestedEast,
  }) {
    return south <= requestedSouth &&
        north >= requestedNorth &&
        west <= requestedWest &&
        east >= requestedEast;
  }

  bool get isExpired {
    return DateTime.now().difference(createdAt) >
        const Duration(minutes: 5);
  }
}

// ==================================================================
// MAP
// ==================================================================

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();

  final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(
    region: 'europe-central2',
  );

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _places = [];

  final List<_ViewportCacheEntry> _viewportCache = [];

  static const int _maxViewportCacheEntries = 8;

  bool _isLoadingPlaces = false;
  bool _reloadRequestedWhileLoading = false;

  int _queryGeneration = 0;

  Timer? _viewportWatcher;

  static const Duration _viewportCheckInterval =
      Duration(milliseconds: 400);

  int _stableViewportChecks = 0;

  String? _lastObservedViewportSignature;
  String? _lastLoadedViewportSignature;

  String? _lastAutomaticAttemptSignature;
  DateTime? _lastAutomaticAttemptAt;

  static const Duration _automaticRetryCooldown =
      Duration(seconds: 10);

  bool _introPopupShown = false;
  bool _welcomePopupShown = false;

  bool _mapReady = false;
  bool _startupStarted = false;

  bool _isLocatingUser = false;

  @override
  void dispose() {
    _viewportWatcher?.cancel();
    super.dispose();
  }

  Future<void> _initializeMap() async {
    if (_startupStarted) {
      return;
    }

    _startupStarted = true;

    await _loadPlacesForCurrentView();

    if (!mounted) {
      return;
    }

    _startViewportWatcher();

    unawaited(
      _moveToUserLocation(
        showError: false,
      ),
    );

    await _showIntroPopup();

    if (!mounted) {
      return;
    }

    await _loadPlacesCount();
  }

  void _startViewportWatcher() {
    _viewportWatcher?.cancel();

    _lastObservedViewportSignature =
        _currentViewportSignature();

    _stableViewportChecks = 0;

    _viewportWatcher = Timer.periodic(
      _viewportCheckInterval,
      (_) {
        _checkVisibleBounds();
      },
    );
  }

  String _currentViewportSignature() {
    final bounds =
        _mapController.camera.visibleBounds;

    final south =
        bounds.southWest.latitude.toStringAsFixed(5);

    final west =
        bounds.southWest.longitude.toStringAsFixed(5);

    final north =
        bounds.northEast.latitude.toStringAsFixed(5);

    final east =
        bounds.northEast.longitude.toStringAsFixed(5);

    return '$south|$west|$north|$east';
  }

  void _checkVisibleBounds() {
    if (!mounted || !_mapReady) {
      return;
    }

    final currentSignature =
        _currentViewportSignature();

    if (currentSignature !=
        _lastObservedViewportSignature) {
      _lastObservedViewportSignature =
          currentSignature;

      _stableViewportChecks = 0;

      return;
    }

    _stableViewportChecks++;

    if (_stableViewportChecks < 1) {
      return;
    }

    if (currentSignature ==
        _lastLoadedViewportSignature) {
      return;
    }

    if (_lastAutomaticAttemptSignature ==
            currentSignature &&
        _lastAutomaticAttemptAt != null) {
      final elapsed =
          DateTime.now().difference(
        _lastAutomaticAttemptAt!,
      );

      if (elapsed <
          _automaticRetryCooldown) {
        return;
      }
    }

    _lastAutomaticAttemptSignature =
        currentSignature;

    _lastAutomaticAttemptAt =
        DateTime.now();

    _loadPlacesForCurrentView();
  }

  Future<void> _moveToUserLocation({
    required bool showError,
  }) async {
    if (_isLocatingUser || !_mapReady) {
      return;
    }

    setState(() {
      _isLocatingUser = true;
    });

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
        if (showError && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Brak dostępu do lokalizacji. '
                'Możesz nadal normalnie korzystać z mapy.',
              ),
            ),
          );
        }

        return;
      }

      final position =
          await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );

      if (!mounted || !_mapReady) {
        return;
      }

      _mapController.move(
        LatLng(
          position.latitude,
          position.longitude,
        ),
        12.5,
      );

      await Future.delayed(
        const Duration(milliseconds: 250),
      );

      if (!mounted) {
        return;
      }

      await _loadPlacesForCurrentView();
    } catch (_) {
      if (showError && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Nie udało się ustalić Twojej lokalizacji. '
              'Możesz nadal przesuwać mapę ręcznie.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLocatingUser = false;
        });
      }
    }
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>>?
      _getPlacesFromViewportCache({
    required double south,
    required double north,
    required double west,
    required double east,
  }) {
    _viewportCache.removeWhere(
      (entry) => entry.isExpired,
    );

    for (final entry
        in _viewportCache.reversed) {
      if (!entry.containsBounds(
        requestedSouth: south,
        requestedNorth: north,
        requestedWest: west,
        requestedEast: east,
      )) {
        continue;
      }

      return entry.places.where(
        (document) {
          final data =
              document.data();

          final lat =
              (data['lat'] as num?)
                  ?.toDouble();

          final lng =
              (data['lng'] as num?)
                  ?.toDouble();

          if (lat == null ||
              lng == null) {
            return false;
          }

          return lat >= south &&
              lat <= north &&
              lng >= west &&
              lng <= east;
        },
      ).toList();
    }

    return null;
  }

  void _saveViewportToCache({
    required double south,
    required double north,
    required double west,
    required double east,
    required List<
            QueryDocumentSnapshot<
                Map<String, dynamic>>>
        places,
  }) {
    _viewportCache.removeWhere(
      (entry) => entry.isExpired,
    );

    _viewportCache.add(
      _ViewportCacheEntry(
        south: south,
        north: north,
        west: west,
        east: east,
        places: List.unmodifiable(
          places,
        ),
        createdAt: DateTime.now(),
      ),
    );

    while (_viewportCache.length >
        _maxViewportCacheEntries) {
      _viewportCache.removeAt(0);
    }
  }

  Query<Map<String, dynamic>>
      _buildPlacesQuery({
    required double south,
    required double north,
    required double west,
    required double east,
  }) {
    return FirebaseFirestore.instance
        .collection('places')
        .where(
          'status',
          whereIn: [
            'pending',
            'confirmed',
            'disputed',
          ],
        )
        .where(
          'lat',
          isGreaterThanOrEqualTo: south,
        )
        .where(
          'lat',
          isLessThanOrEqualTo: north,
        )
        .where(
          'lng',
          isGreaterThanOrEqualTo: west,
        )
        .where(
          'lng',
          isLessThanOrEqualTo: east,
        );
  }

  Future<
          QuerySnapshot<
              Map<String, dynamic>>?>
      _fetchPlacesWithRetry({
    required double south,
    required double north,
    required double west,
    required double east,
    required int requestGeneration,
  }) async {
    const timeout =
        Duration(seconds: 5);

    try {
      return await _buildPlacesQuery(
        south: south,
        north: north,
        west: west,
        east: east,
      ).get().timeout(
            timeout,
          );
    } on TimeoutException {
      if (requestGeneration !=
          _queryGeneration) {
        return null;
      }
    }

    await Future.delayed(
      const Duration(milliseconds: 250),
    );

    if (requestGeneration !=
        _queryGeneration) {
      return null;
    }

    return _buildPlacesQuery(
      south: south,
      north: north,
      west: west,
      east: east,
    ).get().timeout(
          timeout,
        );
  }

  Future<void> _loadPlacesForCurrentView({
    bool forceNetwork = false,
  }) async {
    if (!_mapReady) {
      return;
    }

    final requestGeneration =
        ++_queryGeneration;

    final bounds =
        _mapController.camera.visibleBounds;

    final south =
        bounds.southWest.latitude;

    final north =
        bounds.northEast.latitude;

    final west =
        bounds.southWest.longitude;

    final east =
        bounds.northEast.longitude;

    final requestedViewportSignature =
        _currentViewportSignature();

    if (!forceNetwork) {
      final cachedPlaces =
          _getPlacesFromViewportCache(
        south: south,
        north: north,
        west: west,
        east: east,
      );

      if (cachedPlaces != null &&
          mounted) {
        setState(() {
          _places =
              cachedPlaces;
        });
      }
    }

    if (_isLoadingPlaces) {
      _reloadRequestedWhileLoading =
          true;

      return;
    }

    _isLoadingPlaces = true;

    try {
      final snapshot =
          await _fetchPlacesWithRetry(
        south: south,
        north: north,
        west: west,
        east: east,
        requestGeneration:
            requestGeneration,
      );

      if (!mounted) {
        return;
      }

      if (requestGeneration !=
          _queryGeneration) {
        return;
      }

      if (snapshot == null) {
        return;
      }

      final documents =
          snapshot.docs;

      _saveViewportToCache(
        south: south,
        north: north,
        west: west,
        east: east,
        places: documents,
      );

      setState(() {
        _places =
            documents;
      });

      _lastLoadedViewportSignature =
          requestedViewportSignature;

      _lastAutomaticAttemptSignature =
          null;

      _lastAutomaticAttemptAt =
          null;
    } on TimeoutException {
      if (!mounted) {
        return;
      }

      if (requestGeneration !=
          _queryGeneration) {
        return;
      }

      if (_places.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content: Text(
              'Pobieranie lokali trwa zbyt długo. '
              'Spróbuj użyć odświeżenia.',
            ),
          ),
        );
      }
    } on FirebaseException catch (
        error) {
      if (!mounted) {
        return;
      }

      if (requestGeneration !=
          _queryGeneration) {
        return;
      }

      if (_places.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          SnackBar(
            content: Text(
              'Nie udało się pobrać lokali: '
              '${error.message ?? error.code}',
            ),
          ),
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }

      if (requestGeneration !=
          _queryGeneration) {
        return;
      }

      if (_places.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          SnackBar(
            content: Text(
              'Nie udało się pobrać lokali: $error',
            ),
          ),
        );
      }
    } finally {
      _isLoadingPlaces =
          false;

      if (_reloadRequestedWhileLoading) {
        _reloadRequestedWhileLoading =
            false;

        if (mounted) {
          Future.microtask(
            _loadPlacesForCurrentView,
          );
        }
      }
    }
  }
  // ==================================================================
  // INTRO
  // ==================================================================

  Future<void> _showIntroPopup() async {
    if (!mounted ||
        _introPopupShown) {
      return;
    }

    _introPopupShown = true;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return Dialog(
          insetPadding:
              const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(
              22,
            ),
          ),
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(
              maxWidth: 520,
            ),
            child: Stack(
              children: [
                Padding(
                  padding:
                      const EdgeInsets
                          .fromLTRB(
                    28,
                    30,
                    28,
                    28,
                  ),
                  child:
                      SingleChildScrollView(
                    child: Column(
                      mainAxisSize:
                          MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.water_drop,
                          color:
                              Colors.blue,
                          size: 52,
                        ),
                        const SizedBox(
                          height: 12,
                        ),
                        Container(
                          padding:
                              const EdgeInsets
                                  .symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration:
                              BoxDecoration(
                            color: Colors.blue
                                .withValues(
                              alpha: 0.10,
                            ),
                            borderRadius:
                                BorderRadius
                                    .circular(
                              20,
                            ),
                          ),
                          child:
                              const Text(
                            'WERSJA BETA',
                            style:
                                TextStyle(
                              color:
                                  Colors.blue,
                              fontSize: 12,
                              fontWeight:
                                  FontWeight
                                      .w800,
                              letterSpacing:
                                  0.8,
                            ),
                          ),
                        ),
                        const SizedBox(
                          height: 18,
                        ),
                        const Text(
                          'DarmowaKranówka',
                          textAlign:
                              TextAlign.center,
                          style:
                              TextStyle(
                            fontSize: 25,
                            fontWeight:
                                FontWeight
                                    .w800,
                          ),
                        ),
                        const SizedBox(
                          height: 18,
                        ),
                        const Text(
                          'Pomysł, aby restauracje miały obowiązek '
                          'podawania klientom darmowej wody z kranu, '
                          'ostatecznie nie znalazł się w przepisach.',
                          textAlign:
                              TextAlign.center,
                          style:
                              TextStyle(
                            fontSize: 15,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(
                          height: 14,
                        ),
                        const Text(
                          'My jednak wierzymy, że prawo nie musi być '
                          'jedynym powodem, żeby robić coś dobrze.',
                          textAlign:
                              TextAlign.center,
                          style:
                              TextStyle(
                            fontSize: 15,
                            height: 1.5,
                            fontWeight:
                                FontWeight
                                    .w600,
                          ),
                        ),
                        const SizedBox(
                          height: 14,
                        ),
                        const Text(
                          'Woda nie powinna być luksusem. '
                          'W rozwiniętym kraju dostęp do zwykłej '
                          'kranówki przy posiłku powinien być czymś '
                          'normalnym — i wiemy, że wiele restauracji, '
                          'kawiarni i barów już dziś podaje ją swoim '
                          'gościom bezpłatnie.',
                          textAlign:
                              TextAlign.center,
                          style:
                              TextStyle(
                            fontSize: 15,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(
                          height: 14,
                        ),
                        Text(
                          'DarmowaKranówka powstała po to, '
                          'żeby te miejsca odnaleźć i pokazać innym.',
                          textAlign:
                              TextAlign.center,
                          style:
                              TextStyle(
                            fontSize: 15,
                            height: 1.5,
                            color: Colors
                                .blue
                                .shade800,
                            fontWeight:
                                FontWeight
                                    .w700,
                          ),
                        ),
                        const SizedBox(
                          height: 14,
                        ),
                        const Text(
                          'To projekt społecznościowy. Możesz dodawać '
                          'lokale, w których dostałeś darmową kranówkę, '
                          'potwierdzać istniejące miejsca i pomagać nam '
                          'utrzymywać mapę aktualną.',
                          textAlign:
                              TextAlign.center,
                          style:
                              TextStyle(
                            fontSize: 15,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(
                          height: 14,
                        ),
                        const Text(
                          'Im więcej osób dołączy, '
                          'tym lepsza będzie mapa.',
                          textAlign:
                              TextAlign.center,
                          style:
                              TextStyle(
                            fontSize: 15,
                            height: 1.5,
                            fontWeight:
                                FontWeight
                                    .w700,
                          ),
                        ),
                        const SizedBox(
                          height: 18,
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
                            color: Colors.blue
                                .withValues(
                              alpha: 0.07,
                            ),
                            borderRadius:
                                BorderRadius
                                    .circular(
                              12,
                            ),
                          ),
                          child:
                              const Text(
                            'To wciąż wersja Beta — aplikacja będzie '
                            'się zmieniać i rozwijać razem z jej '
                            'użytkownikami.',
                            textAlign:
                                TextAlign
                                    .center,
                            style:
                                TextStyle(
                              fontSize: 13,
                              height: 1.4,
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
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    tooltip:
                        'Zamknij',
                    onPressed: () {
                      Navigator.of(
                        dialogContext,
                      ).pop();
                    },
                    icon:
                        const Icon(
                      Icons.close,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ==================================================================
  // CONFIRMED COUNT
  // ==================================================================

  Future<void> _loadPlacesCount() async {
    try {
      final results = await Future.wait([
        FirebaseFirestore.instance
            .collection('places')
            .where(
              'status',
              isEqualTo: 'confirmed',
            )
            .count()
            .get(),
        FirebaseFirestore.instance
            .collection('places')
            .where(
              'status',
              isEqualTo: 'pending',
            )
            .count()
            .get(),
      ]);

      if (!mounted) {
        return;
      }

      final confirmedCount =
          results[0].count ?? 0;

      final pendingCount =
          results[1].count ?? 0;

      final totalCount =
          confirmedCount + pendingCount;

      await _showWelcomePopup(
        totalCount,
      );
    } catch (_) {
      if (!mounted) {
        return;
      }

      await _showWelcomePopup(
        0,
      );
    }
  }

  Future<void> _showWelcomePopup(
    int placesCount,
  ) async {
    if (!mounted ||
        _welcomePopupShown) {
      return;
    }

    _welcomePopupShown = true;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return Dialog(
          shape:
              RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(
              20,
            ),
          ),
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(
              maxWidth: 420,
            ),
            child: Padding(
              padding:
                  const EdgeInsets
                      .fromLTRB(
                28,
                30,
                28,
                24,
              ),
              child: Column(
                mainAxisSize:
                    MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.water_drop,
                    color: Colors.blue,
                    size: 48,
                  ),
                  const SizedBox(
                    height: 16,
                  ),
                  Text(
                    placesCount == 1
                        ? 'Na mapie jest już 1 miejsce!'
                        : 'Na mapie jest już $placesCount miejsc!',
                    textAlign:
                        TextAlign.center,
                    style:
                        const TextStyle(
                      fontSize: 22,
                      height: 1.3,
                      fontWeight:
                          FontWeight.w700,
                    ),
                  ),
                  const SizedBox(
                    height: 12,
                  ),
                  const Text(
                    'Pomóż nam rozwijać mapę — '
                    'potwierdzaj istniejące lokale i dodawaj nowe miejsca.',
                    textAlign:
                        TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color:
                          Colors.black54,
                    ),
                  ),
                  const SizedBox(
                    height: 24,
                  ),
                  SizedBox(
                    width:
                        double.infinity,
                    child:
                        FilledButton(
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
                          vertical: 14,
                        ),
                      ),
                      onPressed: () {
                        Navigator.of(
                          dialogContext,
                        ).pop();
                      },
                      child:
                          const Text(
                        'Sprawdź na mapie',
                        style:
                            TextStyle(
                          fontWeight:
                              FontWeight
                                  .w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ==================================================================
  // MARKERS
  // ==================================================================

  int _markerPriority(
    String status,
  ) {
    switch (status) {
      case 'confirmed':
        return 3;

      case 'disputed':
        return 2;

      default:
        return 1;
    }
  }

  List<Marker> _buildMarkers() {
    final sortedPlaces = [
      ..._places,
    ];

    sortedPlaces.sort(
      (
        first,
        second,
      ) {
        final firstStatus =
            first.data()['status']
                    as String? ??
                'pending';

        final secondStatus =
            second.data()['status']
                    as String? ??
                'pending';

        return _markerPriority(
          firstStatus,
        ).compareTo(
          _markerPriority(
            secondStatus,
          ),
        );
      },
    );

    final markers = <Marker>[];

    for (final doc
        in sortedPlaces) {
      final data =
          doc.data();

      final name =
          data['name'] as String? ??
              'Nieznany lokal';

      final address =
          data['address']
                  as String? ??
              'Brak adresu';

      final location =
          data['location']
              as GeoPoint?;

      if (location == null) {
        continue;
      }

      final confirmations =
          (data['confirmations']
                      as num?)
                  ?.toInt() ??
              0;

      final status =
          data['status']
                  as String? ??
              'pending';

      final disputeReason =
          data['disputeReason']
              as String?;

      final Color markerColor;

      switch (status) {
        case 'disputed':
          markerColor =
              Colors.orange;
          break;

        case 'confirmed':
          markerColor =
              Colors
                  .blue.shade700;
          break;

        default:
          markerColor =
              Colors.blueGrey
                  .shade300;
      }

      markers.add(
        Marker(
          point: LatLng(
            location.latitude,
            location.longitude,
          ),
          width: 50,
          height: 50,
          child:
              GestureDetector(
            onTap: () =>
                _showPlace(
              context,
              doc.reference,
              name,
              address,
              confirmations,
              status,
              disputeReason,
            ),
            child: Icon(
              Icons.water_drop,
              size: 42,
              color:
                  markerColor,
            ),
          ),
        ),
      );
    }

    return markers;
  }

  String _disputeReasonLabel(
    String? reason,
  ) {
    switch (reason) {
      case 'no_free_water':
        return 'Zgłoszono, że lokal może już nie podawać '
            'darmowej wody';

      case 'wrong_location':
        return 'Zgłoszono błędny adres lub pozycję lokalu';

      case 'closed':
        return 'Zgłoszono, że lokal może być zamknięty '
            'lub nie istnieć';

      case 'duplicate':
        return 'Zgłoszono, że ten wpis może być duplikatem';

      case 'other':
        return 'Zgłoszono inny problem dotyczący tego lokalu';

      default:
        return 'Informacja o lokalu została zakwestionowana';
    }
  }

  // ==================================================================
  // PLACE MODAL
  // ==================================================================

  Future<void> _showPlace(
    BuildContext context,
    DocumentReference<
            Map<String, dynamic>>
        placeReference,
    String name,
    String address,
    int confirmations,
    String status,
    String? disputeReason,
  ) async {
    final user =
        FirebaseAuth
            .instance.currentUser;

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

    final confirmationReference =
        placeReference
            .collection(
              'userConfirmations',
            )
            .doc(user.uid);

    final reportReference =
        placeReference
            .collection(
              'reports',
            )
            .doc(user.uid);

    bool hasAlreadyConfirmed;
    bool hasAlreadyReported;

    try {
      final results =
          await Future.wait([
        confirmationReference.get(),
        reportReference.get(),
      ]);

      hasAlreadyConfirmed =
          results[0].exists;

      hasAlreadyReported =
          results[1].exists;
    } catch (error) {
      if (!context.mounted) {
        return;
      }

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się pobrać danych lokalu: $error',
          ),
        ),
      );

      return;
    }

    if (!context.mounted) {
      return;
    }

    var displayedConfirmations =
        confirmations;

    var displayedStatus =
        status;

    var displayedDisputeReason =
        disputeReason;

    var isConfirming = false;
    var isReporting = false;

    String? modalMessage;

    bool modalMessageIsError =
        false;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder:
          (bottomSheetContext) {
        return StatefulBuilder(
          builder: (
            modalContext,
            setModalState,
          ) {
            void showModalMessage(
              String message, {
              required bool isError,
            }) {
              setModalState(() {
                modalMessage =
                    message;

                modalMessageIsError =
                    isError;
              });
            }

            Future<void>
                confirmPlace() async {
              if (isConfirming ||
                  hasAlreadyConfirmed ||
                  displayedStatus ==
                      'disputed') {
                return;
              }

              setModalState(() {
                isConfirming = true;

                modalMessage = null;
              });

              try {
                final callable =
                    _functions
                        .httpsCallable(
                  'confirmPlace',
                );

                final result =
                    await callable.call<
                        Map<String,
                            dynamic>>(
                  {
                    'placeId':
                        placeReference
                            .id,
                  },
                );

                if (!modalContext
                    .mounted) {
                  return;
                }

                final confirmationsRaw =
                    result.data[
                        'confirmations'];

                final statusRaw =
                    result.data[
                        'status'];

                final remainingRaw =
                    result.data[
                        'remaining'];

                final newConfirmations =
                    confirmationsRaw
                            is num
                        ? confirmationsRaw
                            .toInt()
                        : displayedConfirmations +
                            1;

                final newStatus =
                    statusRaw
                            is String
                        ? statusRaw
                        : displayedStatus;

                final remaining =
                    remainingRaw
                            is num
                        ? remainingRaw
                            .toInt()
                        : null;

                setModalState(() {
                  displayedConfirmations =
                      newConfirmations;

                  displayedStatus =
                      newStatus;

                  isConfirming =
                      false;

                  hasAlreadyConfirmed =
                      true;
                });

                String message =
                    'Dziękujemy. Potwierdzenie zostało zapisane.';

                if (remaining == 0) {
                  message =
                      'Potwierdzenie zapisane. '
                      'Wykorzystałeś limit 2 potwierdzeń '
                      'na najbliższe 24 godziny.';
                } else if (remaining !=
                    null) {
                  message =
                      'Potwierdzenie zapisane. '
                      'Możesz potwierdzić jeszcze '
                      '$remaining lokal w ciągu 24 godzin.';
                }

                showModalMessage(
                  message,
                  isError: false,
                );

                _loadPlacesForCurrentView(
                  forceNetwork:
                      true,
                );
              } on FirebaseFunctionsException catch (
                  error) {
                if (!modalContext
                    .mounted) {
                  return;
                }

                setModalState(() {
                  isConfirming =
                      false;
                });

                String message;

                switch (
                    error.code) {
                  case 'resource-exhausted':
                    message =
                        'Osiągnąłeś limit 2 potwierdzeń '
                        'w ciągu 24 godzin.';
                    break;

                  case 'already-exists':
                    message =
                        'Ten lokal został już przez Ciebie '
                        'potwierdzony.';

                    setModalState(
                      () {
                        hasAlreadyConfirmed =
                            true;
                      },
                    );

                    break;

                  case 'not-found':
                    message =
                        'Lokal nie istnieje.';
                    break;

                  case 'failed-precondition':
                    message =
                        error.message ??
                            'Tego lokalu nie można obecnie '
                                'potwierdzić.';
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

                  default:
                    message =
                        error.message ??
                            'Nie udało się zapisać potwierdzenia.';
                }

                showModalMessage(
                  message,
                  isError: true,
                );
              } catch (error) {
                if (!modalContext
                    .mounted) {
                  return;
                }

                setModalState(() {
                  isConfirming =
                      false;
                });

                showModalMessage(
                  'Nie udało się zapisać potwierdzenia: $error',
                  isError: true,
                );
              }
            }

            Future<void>
                reportProblem() async {
              if (isReporting ||
                  hasAlreadyReported) {
                return;
              }

              final report =
                  await showModalBottomSheet<
                      PlaceReportData>(
                context:
                    modalContext,
                isScrollControlled:
                    true,
                showDragHandle:
                    true,
                builder: (context) {
                  return const ReportProblemSheet();
                },
              );

              if (report == null ||
                  !modalContext
                      .mounted) {
                return;
              }

              setModalState(() {
                isReporting =
                    true;

                modalMessage =
                    null;
              });

              try {
                final callable =
                    _functions
                        .httpsCallable(
                  'reportPlace',
                );

                final result =
                    await callable.call<
                        Map<String,
                            dynamic>>(
                  {
                    'placeId':
                        placeReference
                            .id,
                    'reason':
                        report.reason,
                    'details':
                        report.details,
                  },
                );

                if (!modalContext
                    .mounted) {
                  return;
                }

                final statusRaw =
                    result.data[
                        'status'];

                final disputeReasonRaw =
                    result.data[
                        'disputeReason'];

                final remainingRaw =
                    result.data[
                        'remaining'];

                final newStatus =
                    statusRaw
                            is String
                        ? statusRaw
                        : 'disputed';

                final newDisputeReason =
                    disputeReasonRaw
                            is String
                        ? disputeReasonRaw
                        : report.reason;

                final remaining =
                    remainingRaw
                            is num
                        ? remainingRaw
                            .toInt()
                        : null;

                setModalState(() {
                  isReporting =
                      false;

                  hasAlreadyReported =
                      true;

                  displayedStatus =
                      newStatus;

                  displayedDisputeReason =
                      newDisputeReason;
                });

                String message =
                    'Zgłoszenie zostało zapisane.';

                if (remaining == 0) {
                  message =
                      'Zgłoszenie zapisane. '
                      'Wykorzystałeś limit 1 zgłoszenia '
                      'na najbliższe 24 godziny.';
                }

                showModalMessage(
                  message,
                  isError: false,
                );

                _loadPlacesForCurrentView(
                  forceNetwork:
                      true,
                );
              } on FirebaseFunctionsException catch (
                  error) {
                if (!modalContext
                    .mounted) {
                  return;
                }

                setModalState(() {
                  isReporting =
                      false;
                });

                String message;

                switch (
                    error.code) {
                  case 'resource-exhausted':
                    message =
                        'Osiągnąłeś limit 1 zgłoszenia '
                        'w ciągu 24 godzin.';
                    break;

                  case 'already-exists':
                    message =
                        'Ten lokal został już przez Ciebie '
                        'zgłoszony.';

                    setModalState(
                      () {
                        hasAlreadyReported =
                            true;
                      },
                    );

                    break;

                  case 'not-found':
                    message =
                        'Lokal nie istnieje.';
                    break;

                  case 'failed-precondition':
                    message =
                        error.message ??
                            'Tego lokalu nie można obecnie '
                                'zgłosić.';
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

                  case 'invalid-argument':
                    message =
                        error.message ??
                            'Nieprawidłowe dane zgłoszenia.';
                    break;

                  default:
                    message =
                        error.message ??
                            'Nie udało się zapisać zgłoszenia.';
                }

                showModalMessage(
                  message,
                  isError: true,
                );
              } catch (error) {
                if (!modalContext
                    .mounted) {
                  return;
                }

                setModalState(() {
                  isReporting =
                      false;
                });

                showModalMessage(
                  'Nie udało się zapisać zgłoszenia: $error',
                  isError: true,
                );
              }
            }

            String statusLabel;

            switch (
                displayedStatus) {
              case 'confirmed':
                statusLabel =
                    'Potwierdzony lokal';
                break;

              case 'disputed':
                statusLabel =
                    'Informacja kwestionowana';
                break;

              default:
                statusLabel =
                    'Nowe zgłoszenie';
            }

            return SafeArea(
              top: false,
              child:
                  SingleChildScrollView(
                padding:
                    const EdgeInsets
                        .fromLTRB(
                  24,
                  8,
                  24,
                  24,
                ),
                child: Column(
                  mainAxisSize:
                      MainAxisSize
                          .min,
                  crossAxisAlignment:
                      CrossAxisAlignment
                          .start,
                  children: [
                    Text(
                      name,
                      style:
                          const TextStyle(
                        fontSize: 22,
                        fontWeight:
                            FontWeight
                                .bold,
                      ),
                    ),
                    const SizedBox(
                      height: 8,
                    ),
                    Text(
                      address,
                    ),
                    const SizedBox(
                      height: 12,
                    ),
                    Text(
                      statusLabel,
                      style:
                          TextStyle(
                        fontWeight:
                            FontWeight
                                .w700,
                        color: displayedStatus ==
                                'disputed'
                            ? Colors
                                .orange
                            : Colors
                                .blue,
                      ),
                    ),
                    if (displayedStatus ==
                        'disputed') ...[
                      const SizedBox(
                        height: 6,
                      ),
                      Container(
                        width:
                            double
                                .infinity,
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
                                0.10,
                          ),
                          borderRadius:
                              BorderRadius
                                  .circular(
                            10,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment:
                              CrossAxisAlignment
                                  .start,
                          children: [
                            const Icon(
                              Icons
                                  .warning_amber_rounded,
                              color:
                                  Colors
                                      .orange,
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
                                _disputeReasonLabel(
                                  displayedDisputeReason,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(
                      height: 12,
                    ),
                    const Row(
                      children: [
                        Icon(
                          Icons
                              .water_drop,
                          color:
                              Colors.blue,
                        ),
                        SizedBox(
                          width: 8,
                        ),
                        Expanded(
                          child: Text(
                            'Darmowa woda do zamówienia',
                            style:
                                TextStyle(
                              fontWeight:
                                  FontWeight
                                      .w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(
                      height: 8,
                    ),
                    Text(
                      'Potwierdzone: '
                      '$displayedConfirmations razy',
                    ),
                    if (modalMessage !=
                        null) ...[
                      const SizedBox(
                        height: 16,
                      ),
                      Container(
                        width:
                            double
                                .infinity,
                        padding:
                            const EdgeInsets
                                .all(
                          12,
                        ),
                        decoration:
                            BoxDecoration(
                          color: modalMessageIsError
                              ? Colors
                                  .red
                                  .withValues(
                                  alpha:
                                      0.08,
                                )
                              : Colors
                                  .blue
                                  .withValues(
                                  alpha:
                                      0.08,
                                ),
                          borderRadius:
                              BorderRadius
                                  .circular(
                            10,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment:
                              CrossAxisAlignment
                                  .start,
                          children: [
                            Icon(
                              modalMessageIsError
                                  ? Icons
                                      .error_outline
                                  : Icons
                                      .check_circle_outline,
                              color:
                                  modalMessageIsError
                                      ? Colors
                                          .red
                                      : Colors
                                          .blue,
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
                                modalMessage!,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(
                      height: 20,
                    ),
                    SizedBox(
                      width:
                          double
                              .infinity,
                      child:
                          FilledButton(
                        onPressed:
                            isConfirming ||
                                    hasAlreadyConfirmed ||
                                    displayedStatus ==
                                        'disputed'
                                ? null
                                : confirmPlace,
                        child:
                            isConfirming
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
                                : Text(
                                    displayedStatus ==
                                            'disputed'
                                        ? 'Potwierdzanie wstrzymane'
                                        : hasAlreadyConfirmed
                                            ? 'Już potwierdziłeś'
                                            : 'Potwierdzam',
                                  ),
                      ),
                    ),
                    const SizedBox(
                      height: 10,
                    ),
                    SizedBox(
                      width:
                          double
                              .infinity,
                      child:
                          OutlinedButton
                              .icon(
                        onPressed:
                            isReporting ||
                                    hasAlreadyReported
                                ? null
                                : reportProblem,
                        icon:
                            isReporting
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
                                : Icon(
                                    hasAlreadyReported
                                        ? Icons
                                            .check_circle
                                        : Icons
                                            .flag_outlined,
                                  ),
                        label: Text(
                          hasAlreadyReported
                              ? 'Problem już zgłoszony'
                              : 'Zgłoś problem',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ==================================================================
  // ADD PLACE
  // ==================================================================

  Future<void>
      _openAddPlaceScreen() async {
    final placeAdded =
        await Navigator.of(context)
            .push<bool>(
      MaterialPageRoute(
        builder: (context) =>
            const AddPlaceScreen(),
      ),
    );

    if (!mounted) {
      return;
    }

    if (placeAdded == true) {
      await _loadPlacesForCurrentView(
        forceNetwork: true,
      );
    }
  }

  // ==================================================================
  // SEARCH
  // ==================================================================

  Future<void> _openLocationSearch() async {
    if (!_mapReady) {
      return;
    }

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
        !mounted ||
        !_mapReady) {
      return;
    }

    _mapController.move(
      LatLng(
        result.latitude,
        result.longitude,
      ),
      result.preferredZoom,
    );

    await Future.delayed(
      const Duration(
        milliseconds: 250,
      ),
    );

    if (!mounted ||
        !_mapReady) {
      return;
    }

    await _loadPlacesForCurrentView();
  }

  // ==================================================================
  // BUILD
  // ==================================================================
  @override
  Widget build(
    BuildContext context,
  ) {
    final markers =
        _buildMarkers();

    final screenWidth =
        MediaQuery.of(context)
            .size
            .width;

    final isMobile =
        screenWidth < 600;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize:
            const Size.fromHeight(
          kToolbarHeight,
        ),
        child: ClipRect(
          child: BackdropFilter(
            filter:
                ImageFilter.blur(
              sigmaX: 12,
              sigmaY: 12,
            ),
            child: AppBar(
              backgroundColor:
                  Colors.white
                      .withValues(
                alpha: 0.62,
              ),
              surfaceTintColor:
                  Colors.transparent,
              elevation: 0,
              scrolledUnderElevation:
                  0,
              title: const Text(
                'DarmowaKranówka',
                style: TextStyle(
                  color:
                      Colors.blue,
                  fontWeight:
                      FontWeight
                          .w700,
                ),
              ),
              actions: [
                IconButton(
                  tooltip:
                      'Szukaj miasta lub adresu',
                  onPressed:
                      _openLocationSearch,
                  icon:
                      const Icon(
                    Icons.search,
                    color:
                        Colors.blue,
                  ),
                ),

                if (!isMobile)
                  TextButton.icon(
                    onPressed:
                        _openAddPlaceScreen,
                    icon:
                        const Icon(
                      Icons
                          .add_location_alt,
                      color:
                          Colors.blue,
                    ),
                    label:
                        const Text(
                      'Dodaj lokal',
                      style:
                          TextStyle(
                        color:
                            Colors.blue,
                        fontWeight:
                            FontWeight
                                .w600,
                      ),
                    ),
                  ),

                SizedBox(
                  width:
                      isMobile
                          ? 6
                          : 12,
                ),
              ],
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController:
                _mapController,
            options: MapOptions(
              initialCenter:
                  const LatLng(
                54.5189,
                18.5305,
              ),
              initialZoom: 12.5,
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
              onMapReady: () {
                _mapReady = true;

                WidgetsBinding
                    .instance
                    .addPostFrameCallback(
                  (_) {
                    _initializeMap();
                  },
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

              MarkerClusterLayerWidget(
                options:
                    MarkerClusterLayerOptions(
                  markers: markers,
                  maxClusterRadius:
                      50,
                  size:
                      const Size(
                    58,
                    58,
                  ),
                  alignment:
                      Alignment.center,
                  padding:
                      const EdgeInsets
                          .all(
                    50,
                  ),
                  maxZoom: 17,
                  builder: (
                    context,
                    clusterMarkers,
                  ) {
                    return Stack(
                      alignment:
                          Alignment.center,
                      children: [
                        Icon(
                          Icons.water_drop,
                          size: 56,
                          color:
                              Colors
                                  .blue
                                  .shade700,
                          shadows:
                              const [
                            Shadow(
                              blurRadius:
                                  6,
                              offset:
                                  Offset(
                                0,
                                2,
                              ),
                              color:
                                  Colors.black26,
                            ),
                          ],
                        ),
                        Padding(
                          padding:
                              const EdgeInsets
                                  .only(
                            bottom: 5,
                          ),
                          child: Text(
                            clusterMarkers
                                .length
                                .toString(),
                            style:
                                const TextStyle(
                              color:
                                  Colors.white,
                              fontWeight:
                                  FontWeight
                                      .w800,
                              fontSize:
                                  14,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
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

          // ========================================================
          // MOBILE ADD PLACE PILL
          // ========================================================

          if (isMobile)
            Positioned(
              left: 14,
              bottom: 62,
              child: Material(
                color:
                    Colors.blue,
                elevation: 4,
                borderRadius:
                    BorderRadius.circular(
                  24,
                ),
                child: InkWell(
                  borderRadius:
                      BorderRadius.circular(
                    24,
                  ),
                  onTap:
                      _openAddPlaceScreen,
                  child: const Padding(
                    padding:
                        EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisSize:
                          MainAxisSize.min,
                      children: [
                        Icon(
                          Icons
                              .add_location_alt,
                          color:
                              Colors.white,
                          size:
                              20,
                        ),
                        SizedBox(
                          width: 8,
                        ),
                        Text(
                          'Dodaj lokal',
                          style:
                              TextStyle(
                            color:
                                Colors.white,
                            fontWeight:
                                FontWeight
                                    .w700,
                            fontSize:
                                14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // ========================================================
          // MAP CONTROLS
          // ========================================================

          Positioned(
            right: 14,
            bottom: 62,
            child: Column(
              children: [
                Material(
                  color:
                      Colors.white,
                  elevation: 4,
                  shape:
                      const CircleBorder(),
                  child: IconButton(
                    tooltip:
                        'Odśwież lokale',
                    onPressed: () {
                      _lastAutomaticAttemptSignature =
                          null;

                      _lastAutomaticAttemptAt =
                          null;

                      _loadPlacesForCurrentView(
                        forceNetwork:
                            true,
                      );
                    },
                    icon:
                        const Icon(
                      Icons.refresh,
                      color:
                          Colors.blue,
                    ),
                  ),
                ),

                const SizedBox(
                  height: 10,
                ),

                Material(
                  color:
                      Colors.white,
                  elevation: 4,
                  shape:
                      const CircleBorder(),
                  child: IconButton(
                    tooltip:
                        'Moja lokalizacja',
                    onPressed:
                        _isLocatingUser
                            ? null
                            : () {
                                _moveToUserLocation(
                                  showError:
                                      true,
                                );
                              },
                    icon:
                        _isLocatingUser
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
                                      Colors.blue,
                                ),
                              )
                            : const Icon(
                                Icons
                                    .my_location,
                                color:
                                    Colors.blue,
                              ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}