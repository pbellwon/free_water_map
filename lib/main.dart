import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'app/free_water_app.dart';
import 'firebase_options.dart';
import 'models/place_report_data.dart';
import 'screens/add_place_screen.dart';
import 'services/authentication_service.dart';
import 'widgets/report_problem_sheet.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  await AuthenticationService.ensureAnonymousUser();

  runApp(const FreeWaterApp());
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _moveToUserLocation();
    });
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

      final position = await Geolocator.getCurrentPosition();

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
      // Jeśli lokalizacji nie uda się pobrać,
      // mapa pozostaje na lokalizacji domyślnej.
    }
  }

  Future<void> _showPlace(
    BuildContext context,
    DocumentReference<Map<String, dynamic>> placeReference,
    String name,
    String address,
    int confirmations,
    String status,
  ) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Nie udało się rozpoznać użytkownika.',
          ),
        ),
      );
      return;
    }

    final confirmationReference = placeReference
        .collection('userConfirmations')
        .doc(user.uid);

    final reportReference = placeReference
        .collection('reports')
        .doc(user.uid);

    bool hasAlreadyConfirmed;
    bool hasAlreadyReported;

    try {
      final results = await Future.wait([
        confirmationReference.get(),
        reportReference.get(),
      ]);

      hasAlreadyConfirmed = results[0].exists;
      hasAlreadyReported = results[1].exists;
    } catch (error) {
      if (!context.mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
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

    var displayedConfirmations = confirmations;
    var displayedStatus = status;
    var isConfirming = false;
    var isReporting = false;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (bottomSheetContext) {
        return StatefulBuilder(
          builder: (modalContext, setModalState) {
            Future<void> confirmPlace() async {
              if (isConfirming ||
                  hasAlreadyConfirmed ||
                  displayedStatus == 'disputed') {
                return;
              }

              setModalState(() {
                isConfirming = true;
              });

              try {
                final batch =
                    FirebaseFirestore.instance.batch();

                final nextConfirmations =
                    displayedConfirmations + 1;

                String nextStatus = displayedStatus;

                if (displayedStatus == 'pending' &&
                    nextConfirmations >= 2) {
                  nextStatus = 'confirmed';
                }

                batch.update(
                  placeReference,
                  {
                    'confirmations': FieldValue.increment(1),
                    'lastConfirmedAt':
                        FieldValue.serverTimestamp(),
                    'status': nextStatus,
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

                if (!modalContext.mounted) {
                  return;
                }

                setModalState(() {
                  displayedConfirmations =
                      nextConfirmations;
                  displayedStatus = nextStatus;
                  isConfirming = false;
                  hasAlreadyConfirmed = true;
                });

                ScaffoldMessenger.of(
                  bottomSheetContext,
                ).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Dziękujemy za potwierdzenie.',
                    ),
                  ),
                );
              } on FirebaseException catch (error) {
                if (!modalContext.mounted) {
                  return;
                }

                setModalState(() {
                  isConfirming = false;
                });

                final message =
                    error.code == 'permission-denied'
                        ? 'Operacja została odrzucona przez reguły bezpieczeństwa.'
                        : 'Nie udało się zapisać potwierdzenia: '
                            '${error.message ?? error.code}';

                ScaffoldMessenger.of(
                  bottomSheetContext,
                ).showSnackBar(
                  SnackBar(
                    content: Text(message),
                  ),
                );
              }
            }

            Future<void> reportProblem() async {
              if (isReporting ||
                  hasAlreadyReported) {
                return;
              }

              final report =
                  await showModalBottomSheet<
                      PlaceReportData>(
                context: modalContext,
                isScrollControlled: true,
                showDragHandle: true,
                builder: (context) {
                  return const ReportProblemSheet();
                },
              );

              if (report == null ||
                  !modalContext.mounted) {
                return;
              }

              setModalState(() {
                isReporting = true;
              });

              try {
                await reportReference.set({
                  'userId': user.uid,
                  'reason': report.reason,
                  'details': report.details,
                  'createdAt':
                      FieldValue.serverTimestamp(),
                  'status': 'open',
                });

                if (!modalContext.mounted) {
                  return;
                }

                setModalState(() {
                  isReporting = false;
                  hasAlreadyReported = true;
                });

                ScaffoldMessenger.of(
                  bottomSheetContext,
                ).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Zgłoszenie zostało zapisane.',
                    ),
                  ),
                );
              } on FirebaseException catch (error) {
                if (!modalContext.mounted) {
                  return;
                }

                setModalState(() {
                  isReporting = false;
                });

                final message =
                    error.code == 'permission-denied'
                        ? 'Ten lokal został już przez Ciebie zgłoszony.'
                        : 'Nie udało się zapisać zgłoszenia: '
                            '${error.message ?? error.code}';

                ScaffoldMessenger.of(
                  bottomSheetContext,
                ).showSnackBar(
                  SnackBar(
                    content: Text(message),
                  ),
                );
              }
            }

            String statusLabel;

            switch (displayedStatus) {
              case 'confirmed':
                statusLabel = 'Potwierdzony lokal';
                break;

              case 'disputed':
                statusLabel =
                    'Informacja kwestionowana';
                break;

              default:
                statusLabel = 'Nowe zgłoszenie';
            }

            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  24,
                  8,
                  24,
                  24,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(address),
                    const SizedBox(height: 12),
                    Text(
                      statusLabel,
                      style: TextStyle(
                        fontWeight:
                            FontWeight.w700,
                        color:
                            displayedStatus ==
                                    'disputed'
                                ? Colors.orange
                                : Colors.blue,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Row(
                      children: [
                        Icon(
                          Icons.water_drop,
                          color: Colors.blue,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Darmowa woda do zamówienia',
                            style: TextStyle(
                              fontWeight:
                                  FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Potwierdzone: '
                      '$displayedConfirmations razy',
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
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
                            alpha: 0.45,
                          ),
                          disabledForegroundColor:
                              Colors.white,
                          padding:
                              const EdgeInsets.symmetric(
                            vertical: 14,
                          ),
                        ),
                        onPressed:
                            isConfirming ||
                                    hasAlreadyConfirmed ||
                                    displayedStatus ==
                                        'disputed'
                                ? null
                                : confirmPlace,
                        child: isConfirming
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child:
                                    CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
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
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child:
                          OutlinedButton.icon(
                        onPressed:
                            isReporting ||
                                    hasAlreadyReported
                                ? null
                                : reportProblem,
                        icon: isReporting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                hasAlreadyReported
                                    ? Icons.check_circle
                                    : Icons.flag_outlined,
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

  void _openAddPlaceScreen() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            const AddPlaceScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize:
            const Size.fromHeight(
          kToolbarHeight,
        ),
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: 12,
              sigmaY: 12,
            ),
            child: AppBar(
              backgroundColor:
                  Colors.white.withValues(
                alpha: 0.62,
              ),
              surfaceTintColor:
                  Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              title: const Text(
                'DarmowaKranówka',
                style: TextStyle(
                  color: Colors.blue,
                  fontWeight:
                      FontWeight.w700,
                ),
              ),
              actions: [
                TextButton.icon(
                  onPressed:
                      _openAddPlaceScreen,
                  icon: const Icon(
                    Icons.add_location_alt,
                    color: Colors.blue,
                  ),
                  label: const Text(
                    'Dodaj lokal',
                    style: TextStyle(
                      color: Colors.blue,
                      fontWeight:
                          FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
      body: StreamBuilder<
          QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('places')
            .where(
              'status',
              whereIn: [
                'pending',
                'confirmed',
                'disputed',
              ],
            )
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
              child:
                  CircularProgressIndicator(),
            );
          }

          final places =
              snapshot.data?.docs ?? [];

          return FlutterMap(
            mapController: _mapController,
            options: const MapOptions(
              initialCenter: LatLng(
                54.5189,
                18.5305,
              ),
              initialZoom: 13,
              interactionOptions:
                  InteractionOptions(
                flags:
                    InteractiveFlag.drag |
                    InteractiveFlag.pinchZoom |
                    InteractiveFlag.doubleTapZoom |
                    InteractiveFlag.scrollWheelZoom,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/'
                    '{z}/{x}/{y}.png',
                userAgentPackageName:
                    'pl.freewater.app',
              ),
              MarkerLayer(
                markers: places.map((doc) {
                  final data = doc.data();

                  final name =
                      data['name'] as String? ??
                          'Nieznany lokal';

                  final address =
                      data['address'] as String? ??
                          'Brak adresu';

                  final location =
                      data['location'] as GeoPoint?;

                  final confirmations =
                      (data['confirmations'] as num?)
                              ?.toInt() ??
                          0;

                  final status =
                      data['status'] as String? ??
                          'pending';

                  if (location == null) {
                    return null;
                  }

                  final markerColor =
                      status == 'disputed'
                          ? Colors.orange
                          : status == 'pending'
                              ? Colors.blueGrey
                                  .shade300
                              : Colors.blue
                                  .shade700;

                  return Marker(
                    point: LatLng(
                      location.latitude,
                      location.longitude,
                    ),
                    width: 50,
                    height: 50,
                    child: GestureDetector(
                      onTap: () =>
                          _showPlace(
                        context,
                        doc.reference,
                        name,
                        address,
                        confirmations,
                        status,
                      ),
                      child: Icon(
                        Icons.water_drop,
                        size: 42,
                        color: markerColor,
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