import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

class LocationSearchResult {
  final String name;
  final String? formatted;
  final double latitude;
  final double longitude;
  final String? resultType;

  const LocationSearchResult({
    required this.name,
    required this.formatted,
    required this.latitude,
    required this.longitude,
    required this.resultType,
  });

  factory LocationSearchResult.fromMap(
    Map<String, dynamic> data,
  ) {
    final lat =
        data['lat'];

    final lng =
        data['lng'];

    if (lat is! num || lng is! num) {
      throw const FormatException(
        'Brak poprawnych współrzędnych.',
      );
    }

    return LocationSearchResult(
      name:
          data['name'] is String &&
                  (data['name'] as String)
                      .trim()
                      .isNotEmpty
              ? (data['name'] as String)
                  .trim()
              : 'Lokalizacja',
      formatted:
          data['formatted'] is String
              ? data['formatted']
                  as String
              : null,
      latitude:
          lat.toDouble(),
      longitude:
          lng.toDouble(),
      resultType:
          data['resultType']
                  is String
              ? data['resultType']
                  as String
              : null,
    );
  }

  double get preferredZoom {
    switch (resultType) {
      case 'city':
      case 'town':
      case 'village':
      case 'municipality':
        return 12.5;

      case 'suburb':
      case 'district':
        return 14.0;

      default:
        return 15.5;
    }
  }
}

class LocationSearchDialog
    extends StatefulWidget {
  final FirebaseFunctions functions;

  const LocationSearchDialog({
    super.key,
    required this.functions,
  });

  @override
  State<LocationSearchDialog>
      createState() =>
          _LocationSearchDialogState();
}

class _LocationSearchDialogState
    extends State<LocationSearchDialog> {
  final TextEditingController
      _controller =
      TextEditingController();

  List<LocationSearchResult>
      _results = [];

  bool _isSearching = false;

  String? _errorMessage;

  @override
  void dispose() {
    _controller.dispose();

    super.dispose();
  }

  Future<void> _search() async {
    if (_isSearching) {
      return;
    }

    final query =
        _controller.text.trim();

    if (query.length < 3) {
      setState(() {
        _results = [];

        _errorMessage =
            'Wpisz co najmniej 3 znaki.';
      });

      return;
    }

    setState(() {
      _isSearching = true;

      _errorMessage = null;
    });

    try {
      final callable =
          widget.functions
              .httpsCallable(
        'searchLocation',
      );

      final result =
          await callable.call<
              Map<String, dynamic>>(
        {
          'query': query,
        },
      );

      final rawResults =
          result.data['results'];

      final parsedResults =
          <LocationSearchResult>[];

      if (rawResults is List) {
        for (final rawResult
            in rawResults) {
          if (rawResult is! Map) {
            continue;
          }

          try {
            parsedResults.add(
              LocationSearchResult
                  .fromMap(
                Map<String, dynamic>
                    .from(
                  rawResult,
                ),
              ),
            );
          } catch (_) {
            // Pomijamy pojedynczy
            // nieprawidłowy wynik.
          }
        }
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _results =
            parsedResults;

        _isSearching =
            false;

        if (parsedResults.isEmpty) {
          _errorMessage =
              'Nie znaleziono lokalizacji.';
        }
      });
    } on FirebaseFunctionsException catch (
        error) {
      if (!mounted) {
        return;
      }

      String message;

      switch (error.code) {
        case 'invalid-argument':
          message =
              error.message ??
                  'Nieprawidłowa fraza wyszukiwania.';
          break;

        case 'unauthenticated':
          message =
              'Nie udało się rozpoznać użytkownika. '
              'Odśwież aplikację i spróbuj ponownie.';
          break;

        case 'permission-denied':
          message =
              'Wyszukiwanie nie jest obecnie dostępne.';
          break;

        case 'failed-precondition':
          message =
              'Nie udało się zweryfikować aplikacji. '
              'Odśwież stronę i spróbuj ponownie.';
          break;

        default:
          message =
              error.message ??
                  'Nie udało się wyszukać lokalizacji.';
      }

      setState(() {
        _results = [];

        _isSearching =
            false;

        _errorMessage =
            message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _results = [];

        _isSearching =
            false;

        _errorMessage =
            'Nie udało się wyszukać lokalizacji.';
      });
    }
  }

  void _clear() {
    _controller.clear();

    setState(() {
      _results = [];

      _errorMessage = null;
    });
  }

  void _selectResult(
    LocationSearchResult result,
  ) {
    Navigator.of(context).pop(
      result,
    );
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Dialog(
      insetPadding:
          const EdgeInsets.symmetric(
        horizontal: 20,
        vertical: 24,
      ),
      shape:
          RoundedRectangleBorder(
        borderRadius:
            BorderRadius.circular(
          18,
        ),
      ),
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(
          maxWidth: 520,
          maxHeight: 620,
        ),
        child: Padding(
          padding:
              const EdgeInsets.all(
            20,
          ),
          child: Column(
            mainAxisSize:
                MainAxisSize.min,
            crossAxisAlignment:
                CrossAxisAlignment
                    .start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Szukaj na mapie',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight:
                            FontWeight
                                .w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip:
                        'Zamknij',
                    onPressed: () {
                      Navigator.of(
                        context,
                      ).pop();
                    },
                    icon:
                        const Icon(
                      Icons.close,
                    ),
                  ),
                ],
              ),
              const SizedBox(
                height: 4,
              ),
              const Text(
                'Wpisz miasto, ulicę lub pełny adres.',
                style: TextStyle(
                  color:
                      Colors.black54,
                ),
              ),
              const SizedBox(
                height: 16,
              ),
              TextField(
                controller:
                    _controller,
                autofocus: true,
                textInputAction:
                    TextInputAction
                        .search,
                onSubmitted: (_) {
                  _search();
                },
                onChanged: (_) {
                  setState(() {});
                },
                decoration:
                    InputDecoration(
                  hintText:
                      'np. Wrocław lub Świętojańska 10, Gdynia',
                  prefixIcon:
                      const Icon(
                    Icons.search,
                  ),
                  suffixIcon:
                      _controller.text
                              .isEmpty
                          ? null
                          : IconButton(
                              tooltip:
                                  'Wyczyść',
                              onPressed:
                                  _clear,
                              icon:
                                  const Icon(
                                Icons
                                    .close,
                              ),
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
                height: 12,
              ),
              SizedBox(
                width:
                    double.infinity,
                child:
                    FilledButton.icon(
                  onPressed:
                      _isSearching
                          ? null
                          : _search,
                  icon:
                      _isSearching
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(
                                strokeWidth:
                                    2,
                                color:
                                    Colors
                                        .white,
                              ),
                            )
                          : const Icon(
                              Icons
                                  .search,
                            ),
                  label: Text(
                    _isSearching
                        ? 'Szukam...'
                        : 'Szukaj',
                  ),
                ),
              ),
              if (_errorMessage !=
                  null) ...[
                const SizedBox(
                  height: 14,
                ),
                Container(
                  width:
                      double.infinity,
                  padding:
                      const EdgeInsets
                          .all(
                    12,
                  ),
                  decoration:
                      BoxDecoration(
                    color: Colors.red
                        .withValues(
                      alpha: 0.07,
                    ),
                    borderRadius:
                        BorderRadius
                            .circular(
                      10,
                    ),
                  ),
                  child: Text(
                    _errorMessage!,
                    style:
                        const TextStyle(
                      color:
                          Colors.red,
                    ),
                  ),
                ),
              ],
              if (_results
                  .isNotEmpty) ...[
                const SizedBox(
                  height: 12,
                ),
                const Divider(
                  height: 1,
                ),
                const SizedBox(
                  height: 4,
                ),
                Flexible(
                  child:
                      ListView.separated(
                    shrinkWrap: true,
                    itemCount:
                        _results.length,
                    separatorBuilder:
                        (
                      context,
                      index,
                    ) =>
                            const Divider(
                      height: 1,
                    ),
                    itemBuilder: (
                      context,
                      index,
                    ) {
                      final result =
                          _results[
                              index];

                      final formatted =
                          result
                              .formatted;

                      return ListTile(
                        contentPadding:
                            EdgeInsets
                                .zero,
                        leading:
                            const Icon(
                          Icons
                              .location_on_outlined,
                          color:
                              Colors.blue,
                        ),
                        title: Text(
                          result.name,
                        ),
                        subtitle:
                            formatted ==
                                        null ||
                                    formatted
                                            .trim()
                                            .isEmpty ||
                                    formatted ==
                                        result
                                            .name
                                ? null
                                : Text(
                                    formatted,
                                  ),
                        trailing:
                            const Icon(
                          Icons
                              .chevron_right,
                        ),
                        onTap: () {
                          _selectResult(
                            result,
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}