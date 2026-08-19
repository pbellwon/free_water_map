const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");

const { initializeApp } = require("firebase-admin/app");
const {
  getFirestore,
  GeoPoint,
  Timestamp,
} = require("firebase-admin/firestore");

const {
  geohashForLocation,
  geohashQueryBounds,
} = require("geofire-common");

const GEOAPIFY_API_KEY = defineSecret("GEOAPIFY_API_KEY");

initializeApp();

const PLACE_LIMIT_24H = 2;
const CONFIRMATION_LIMIT_24H = 2;
const REPORT_LIMIT_24H = 1;

const WINDOW_MS = 24 * 60 * 60 * 1000;

function requireAnonymousUser(request) {
  if (!request.auth) {
    throw new HttpsError(
      "unauthenticated",
      "Musisz być zalogowany anonimowo.",
    );
  }

  const provider =
    request.auth.token?.firebase?.sign_in_provider;

  if (provider !== "anonymous") {
    throw new HttpsError(
      "permission-denied",
      "Ta operacja jest dostępna tylko dla użytkowników anonimowych.",
    );
  }

  return request.auth.uid;
}

function filterLast24Hours(
  timestamps,
  cutoffMilliseconds,
) {
  if (!Array.isArray(timestamps)) {
    return [];
  }

  return timestamps.filter(
    (timestamp) =>
      timestamp &&
      typeof timestamp.toMillis === "function" &&
      timestamp.toMillis() > cutoffMilliseconds,
  );
}

function isValidReportReason(reason) {
  return [
    "no_free_water",
    "wrong_location",
    "closed",
    "duplicate",
    "other",
  ].includes(reason);
}

/*
 * ============================================================
 * CREATE PLACE
 * ============================================================
 */

exports.createPlace = onCall(
  {
    region: "europe-central2",
    enforceAppCheck: true,
  },
  async (request) => {
    const uid = requireAnonymousUser(request);

    const {
      name,
      address,
      latitude,
      longitude,
      category,
    } = request.data ?? {};

    if (
      typeof name !== "string" ||
      name.trim().length < 2 ||
      name.trim().length > 120
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Nazwa lokalu musi mieć od 2 do 120 znaków.",
      );
    }

    if (
      typeof address !== "string" ||
      address.trim().length < 3 ||
      address.trim().length > 200
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Adres lokalu musi mieć od 3 do 200 znaków.",
      );
    }

    if (
      typeof latitude !== "number" ||
      typeof longitude !== "number" ||
      latitude < -90 ||
      latitude > 90 ||
      longitude < -180 ||
      longitude > 180
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Nieprawidłowe współrzędne.",
      );
    }

    if (
      ![
        "restaurant",
        "cafe",
        "bar",
        "other",
      ].includes(category)
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Nieprawidłowa kategoria lokalu.",
      );
    }

    const db = getFirestore();

    const now = Timestamp.now();
    const cutoff =
      Date.now() - WINDOW_MS;

    const rateLimitRef = db
      .collection("_rateLimits")
      .doc(uid);

    const placeRef = db
      .collection("places")
      .doc();

    const confirmationRef = placeRef
      .collection("userConfirmations")
      .doc(uid);

    const geohash =
      geohashForLocation([
        latitude,
        longitude,
      ]);

    let remaining =
      PLACE_LIMIT_24H - 1;

    await db.runTransaction(
      async (transaction) => {
        const rateLimitSnapshot =
          await transaction.get(
            rateLimitRef,
          );

        const rateLimitData =
          rateLimitSnapshot.data() ?? {};

        const timestamps =
          filterLast24Hours(
            rateLimitData
              .placeCreateTimestamps,
            cutoff,
          );

        if (
          timestamps.length >=
          PLACE_LIMIT_24H
        ) {
          throw new HttpsError(
            "resource-exhausted",
            "Osiągnąłeś limit 2 nowych lokali w ciągu 24 godzin.",
          );
        }

        const updatedTimestamps = [
          ...timestamps,
          now,
        ];

        remaining = Math.max(
          0,
          PLACE_LIMIT_24H -
            updatedTimestamps.length,
        );

        transaction.set(
          rateLimitRef,
          {
            placeCreateTimestamps:
              updatedTimestamps,
            updatedAt: now,
          },
          {
            merge: true,
          },
        );

        transaction.set(
          placeRef,
          {
            name: name.trim(),
            address: address.trim(),

            location: new GeoPoint(
              latitude,
              longitude,
            ),

            lat: latitude,
            lng: longitude,
            geohash,

            category,

            confirmations: 1,
            status: "pending",

            createdBy: uid,
            createdAt: now,
            lastConfirmedAt: now,
          },
        );

        transaction.set(
          confirmationRef,
          {
            userId: uid,
            createdAt: now,
          },
        );
      },
    );

    return {
      success: true,
      placeId: placeRef.id,
      remaining,
    };
  },
);

/*
 * ============================================================
 * CONFIRM PLACE
 * ============================================================
 */

exports.confirmPlace = onCall(
  {
    region: "europe-central2",
    enforceAppCheck: true,
  },
  async (request) => {
    const uid =
      requireAnonymousUser(request);

    const placeId =
      request.data?.placeId;

    if (
      typeof placeId !== "string" ||
      placeId.trim().length === 0
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Brak identyfikatora lokalu.",
      );
    }

    const db = getFirestore();

    const now = Timestamp.now();
    const cutoff =
      Date.now() - WINDOW_MS;

    const placeRef = db
      .collection("places")
      .doc(placeId);

    const confirmationRef = placeRef
      .collection("userConfirmations")
      .doc(uid);

    const rateLimitRef = db
      .collection("_rateLimits")
      .doc(uid);

    let newConfirmations = 0;
    let newStatus = "pending";

    let remaining =
      CONFIRMATION_LIMIT_24H - 1;

    await db.runTransaction(
      async (transaction) => {
        const [
          placeSnapshot,
          confirmationSnapshot,
          rateLimitSnapshot,
        ] = await Promise.all([
          transaction.get(placeRef),
          transaction.get(
            confirmationRef,
          ),
          transaction.get(
            rateLimitRef,
          ),
        ]);

        if (!placeSnapshot.exists) {
          throw new HttpsError(
            "not-found",
            "Lokal nie istnieje.",
          );
        }

        if (
          confirmationSnapshot.exists
        ) {
          throw new HttpsError(
            "already-exists",
            "Ten lokal został już przez Ciebie potwierdzony.",
          );
        }

        const placeData =
          placeSnapshot.data();

        const currentStatus =
          placeData.status;

        if (
          ![
            "pending",
            "confirmed",
          ].includes(currentStatus)
        ) {
          throw new HttpsError(
            "failed-precondition",
            "Tego lokalu nie można obecnie potwierdzić.",
          );
        }

        const rateLimitData =
          rateLimitSnapshot.data() ?? {};

        const timestamps =
          filterLast24Hours(
            rateLimitData
              .confirmationTimestamps,
            cutoff,
          );

        if (
          timestamps.length >=
          CONFIRMATION_LIMIT_24H
        ) {
          throw new HttpsError(
            "resource-exhausted",
            "Osiągnąłeś limit 2 potwierdzeń w ciągu 24 godzin.",
          );
        }

        const updatedTimestamps = [
          ...timestamps,
          now,
        ];

        remaining = Math.max(
          0,
          CONFIRMATION_LIMIT_24H -
            updatedTimestamps.length,
        );

        newConfirmations =
          (Number(
            placeData.confirmations,
          ) || 0) + 1;

        newStatus =
          newConfirmations >= 2
            ? "confirmed"
            : currentStatus;

        transaction.update(
          placeRef,
          {
            confirmations:
              newConfirmations,

            status: newStatus,
            lastConfirmedAt: now,
          },
        );

        transaction.set(
          confirmationRef,
          {
            userId: uid,
            createdAt: now,
          },
        );

        transaction.set(
          rateLimitRef,
          {
            confirmationTimestamps:
              updatedTimestamps,

            updatedAt: now,
          },
          {
            merge: true,
          },
        );
      },
    );

    return {
      success: true,
      confirmations:
        newConfirmations,
      status: newStatus,
      remaining,
    };
  },
);

/*
 * ============================================================
 * REPORT PLACE
 * ============================================================
 */

exports.reportPlace = onCall(
  {
    region: "europe-central2",
    enforceAppCheck: true,
  },
  async (request) => {
    const uid =
      requireAnonymousUser(request);

    const placeId =
      request.data?.placeId;

    const reason =
      request.data?.reason;

    const details =
      typeof request.data?.details ===
      "string"
        ? request.data.details.trim()
        : "";

    if (
      typeof placeId !== "string" ||
      placeId.trim().length === 0
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Brak identyfikatora lokalu.",
      );
    }

    if (
      !isValidReportReason(reason)
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Nieprawidłowy powód zgłoszenia.",
      );
    }

    if (details.length > 500) {
      throw new HttpsError(
        "invalid-argument",
        "Opis zgłoszenia może mieć maksymalnie 500 znaków.",
      );
    }

    const db = getFirestore();

    const now = Timestamp.now();
    const cutoff =
      Date.now() - WINDOW_MS;

    const placeRef = db
      .collection("places")
      .doc(placeId);

    const reportRef = placeRef
      .collection("reports")
      .doc(uid);

    const rateLimitRef = db
      .collection("_rateLimits")
      .doc(uid);

    let resultingStatus =
      "disputed";

    let resultingDisputeReason =
      reason;

    let remaining =
      REPORT_LIMIT_24H - 1;

    await db.runTransaction(
      async (transaction) => {
        const [
          placeSnapshot,
          reportSnapshot,
          rateLimitSnapshot,
        ] = await Promise.all([
          transaction.get(placeRef),
          transaction.get(
            reportRef,
          ),
          transaction.get(
            rateLimitRef,
          ),
        ]);

        if (!placeSnapshot.exists) {
          throw new HttpsError(
            "not-found",
            "Lokal nie istnieje.",
          );
        }

        if (reportSnapshot.exists) {
          throw new HttpsError(
            "already-exists",
            "Ten lokal został już przez Ciebie zgłoszony.",
          );
        }

        const placeData =
          placeSnapshot.data();

        if (
          ![
            "pending",
            "confirmed",
            "disputed",
          ].includes(
            placeData.status,
          )
        ) {
          throw new HttpsError(
            "failed-precondition",
            "Tego lokalu nie można obecnie zgłosić.",
          );
        }

        const rateLimitData =
          rateLimitSnapshot.data() ?? {};

        const timestamps =
          filterLast24Hours(
            rateLimitData
              .reportTimestamps,
            cutoff,
          );

        if (
          timestamps.length >=
          REPORT_LIMIT_24H
        ) {
          throw new HttpsError(
            "resource-exhausted",
            "Osiągnąłeś limit 1 zgłoszenia w ciągu 24 godzin.",
          );
        }

        const updatedTimestamps = [
          ...timestamps,
          now,
        ];

        remaining = Math.max(
          0,
          REPORT_LIMIT_24H -
            updatedTimestamps.length,
        );

        if (
          placeData.status !==
          "disputed"
        ) {
          transaction.update(
            placeRef,
            {
              status: "disputed",
              disputeReason:
                reason,
              disputedAt: now,
            },
          );

          resultingDisputeReason =
            reason;
        } else {
          resultingDisputeReason =
            placeData
              .disputeReason ??
            reason;
        }

        transaction.set(
          reportRef,
          {
            userId: uid,
            reason,
            details,
            createdAt: now,
            status: "open",
          },
        );

        transaction.set(
          rateLimitRef,
          {
            reportTimestamps:
              updatedTimestamps,

            updatedAt: now,
          },
          {
            merge: true,
          },
        );
      },
    );

    return {
      success: true,
      status:
        resultingStatus,
      disputeReason:
        resultingDisputeReason,
      remaining,
    };
  },
);

/*
 * ============================================================
 * GET PLACES IN VIEWPORT — GEOHASH
 * ============================================================
 */

exports.getPlacesInViewport = onCall(
  {
    region: "europe-central2",
    enforceAppCheck: true,
  },
  async (request) => {
    const {
      south,
      north,
      west,
      east,
    } = request.data ?? {};

    if (
      typeof south !== "number" ||
      typeof north !== "number" ||
      typeof west !== "number" ||
      typeof east !== "number" ||
      south < -90 ||
      south > 90 ||
      north < -90 ||
      north > 90 ||
      west < -180 ||
      west > 180 ||
      east < -180 ||
      east > 180 ||
      south >= north
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Nieprawidłowe granice mapy.",
      );
    }

    if (west >= east) {
      throw new HttpsError(
        "invalid-argument",
        "Viewport przecinający antypołudnik nie jest obsługiwany.",
      );
    }

    const centerLatitude =
      (south + north) / 2;

    const centerLongitude =
      (west + east) / 2;

    const radiusMeters = Math.max(
      haversineDistanceMeters(
        centerLatitude,
        centerLongitude,
        south,
        west,
      ),
      haversineDistanceMeters(
        centerLatitude,
        centerLongitude,
        south,
        east,
      ),
      haversineDistanceMeters(
        centerLatitude,
        centerLongitude,
        north,
        west,
      ),
      haversineDistanceMeters(
        centerLatitude,
        centerLongitude,
        north,
        east,
      ),
    );

    if (
      !Number.isFinite(radiusMeters) ||
      radiusMeters <= 0 ||
      radiusMeters > 2_000_000
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Widoczny obszar mapy jest zbyt duży.",
      );
    }

    const bounds =
      geohashQueryBounds(
        [
          centerLatitude,
          centerLongitude,
        ],
        radiusMeters,
      );

    const db = getFirestore();

    const snapshots =
      await Promise.all(
        bounds.map(
          ([start, end]) =>
            db
              .collection("places")
              .orderBy("geohash")
              .startAt(start)
              .endAt(end)
              .get(),
        ),
      );

    const allowedStatuses =
      new Set([
        "pending",
        "confirmed",
        "disputed",
      ]);

    const uniquePlaces =
      new Map();

    for (const snapshot of snapshots) {
      for (const document of snapshot.docs) {
        if (uniquePlaces.has(document.id)) {
          continue;
        }

        const data =
          document.data();

        const latitude =
          typeof data.lat === "number"
            ? data.lat
            : data.location?.latitude;

        const longitude =
          typeof data.lng === "number"
            ? data.lng
            : data.location?.longitude;

        if (
          typeof latitude !== "number" ||
          typeof longitude !== "number"
        ) {
          continue;
        }

        if (
          latitude < south ||
          latitude > north ||
          longitude < west ||
          longitude > east
        ) {
          continue;
        }

        if (!allowedStatuses.has(data.status)) {
          continue;
        }

        uniquePlaces.set(
          document.id,
          {
            id: document.id,

            name:
              typeof data.name === "string"
                ? data.name
                : "Nieznany lokal",

            address:
              typeof data.address === "string"
                ? data.address
                : "Brak adresu",

            lat: latitude,
            lng: longitude,

            category:
              typeof data.category === "string"
                ? data.category
                : "other",

            status:
              typeof data.status === "string"
                ? data.status
                : "pending",

            confirmations:
              Number(data.confirmations) || 0,

            disputeReason:
              typeof data.disputeReason === "string"
                ? data.disputeReason
                : null,

            createdAt:
              typeof data.createdAt?.toMillis === "function"
                ? data.createdAt.toMillis()
                : null,

            lastConfirmedAt:
              typeof data.lastConfirmedAt?.toMillis === "function"
                ? data.lastConfirmedAt.toMillis()
                : null,
          },
        );
      }
    }

    const places =
      Array.from(
        uniquePlaces.values(),
      );

    if (places.length > 1500) {
      throw new HttpsError(
        "resource-exhausted",
        "W widocznym obszarze znajduje się zbyt wiele lokali. Przybliż mapę.",
      );
    }

    return {
      places,
      count: places.length,
    };
  },
);

function haversineDistanceMeters(
  latitude1,
  longitude1,
  latitude2,
  longitude2,
) {
  const earthRadiusMeters =
    6_371_000;

  const toRadians =
    (degrees) =>
      (degrees * Math.PI) / 180;

  const latitudeDelta =
    toRadians(
      latitude2 - latitude1,
    );

  const longitudeDelta =
    toRadians(
      longitude2 - longitude1,
    );

  const latitude1Radians =
    toRadians(latitude1);

  const latitude2Radians =
    toRadians(latitude2);

  const a =
    Math.sin(latitudeDelta / 2) ** 2 +
    Math.cos(latitude1Radians) *
      Math.cos(latitude2Radians) *
      Math.sin(longitudeDelta / 2) ** 2;

  const c =
    2 *
    Math.atan2(
      Math.sqrt(a),
      Math.sqrt(1 - a),
    );

  return earthRadiusMeters * c;
}

/*
 * ============================================================
 * RECOGNIZE PLACE — GEOAPIFY
 * ============================================================
 */

exports.recognizePlace = onCall(
  {
    region: "europe-central2",
    enforceAppCheck: true,
    secrets: [
      GEOAPIFY_API_KEY,
    ],
  },
  async (request) => {
    requireAnonymousUser(request);

    const latitude =
      request.data?.latitude;

    const longitude =
      request.data?.longitude;

    if (
      typeof latitude !== "number" ||
      typeof longitude !== "number" ||
      latitude < -90 ||
      latitude > 90 ||
      longitude < -180 ||
      longitude > 180
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Nieprawidłowe współrzędne.",
      );
    }

    const apiKey =
      GEOAPIFY_API_KEY.value();

    /*
     * Szukamy lokali gastronomicznych
     * do 50 metrów od pinezki.
     */

    const placesUrl =
      "https://api.geoapify.com/v2/places" +
      "?categories=catering" +
      `&filter=circle:${longitude},${latitude},50` +
      `&bias=proximity:${longitude},${latitude}` +
      "&limit=5" +
      `&apiKey=${encodeURIComponent(apiKey)}`;

    /*
     * Osobne reverse geocoding
     * dla dokładnego adresu.
     */

    const reverseUrl =
      "https://api.geoapify.com/v1/geocode/reverse" +
      `?lat=${latitude}` +
      `&lon=${longitude}` +
      "&format=json" +
      `&apiKey=${encodeURIComponent(apiKey)}`;

    let placesResponse;
    let reverseResponse;

    try {
      [
        placesResponse,
        reverseResponse,
      ] = await Promise.all([
        fetch(placesUrl),
        fetch(reverseUrl),
      ]);
    } catch (error) {
      console.error(
        "Geoapify network error:",
        error,
      );

      throw new HttpsError(
        "internal",
        "Nie udało się połączyć z usługą rozpoznawania lokalu.",
      );
    }

    if (!placesResponse.ok) {
      console.error(
        "Geoapify Places error:",
        placesResponse.status,
        await placesResponse.text(),
      );

      throw new HttpsError(
        "internal",
        "Nie udało się pobrać informacji o lokalu.",
      );
    }

    if (!reverseResponse.ok) {
      console.error(
        "Geoapify Reverse error:",
        reverseResponse.status,
        await reverseResponse.text(),
      );

      throw new HttpsError(
        "internal",
        "Nie udało się pobrać adresu lokalu.",
      );
    }

    const placesData =
      await placesResponse.json();

    const reverseData =
      await reverseResponse.json();

    /*
     * Geoapify zwraca miejsca posortowane
     * według dopasowania / odległości.
     * Bierzemy pierwsze.
     */

    const place =
      Array.isArray(
        placesData?.features,
      ) &&
      placesData.features.length > 0
        ? placesData.features[0]
        : null;

    const placeProperties =
      place?.properties ?? null;

    const reverseResult =
      Array.isArray(
        reverseData?.results,
      ) &&
      reverseData.results.length > 0
        ? reverseData.results[0]
        : null;

    /*
     * Mapowanie kategorii Geoapify
     * na nasze 4 kategorie.
     */

    let category = "other";

    const categories =
      Array.isArray(
        placeProperties?.categories,
      )
        ? placeProperties.categories
        : [];

    if (
      categories.some(
        (value) =>
          String(value).includes(
            "restaurant",
          ),
      )
    ) {
      category = "restaurant";
    } else if (
      categories.some(
        (value) =>
          String(value).includes(
            "cafe",
          ),
      )
    ) {
      category = "cafe";
    } else if (
      categories.some(
        (value) =>
          String(value).includes(
            "bar",
          ) ||
          String(value).includes(
            "pub",
          ),
      )
    ) {
      category = "bar";
    }

    return {
      name:
        placeProperties?.name ??
        null,

      address:
        reverseResult?.formatted ??
        reverseResult
          ?.address_line2 ??
        null,

      category,

      provider: "geoapify",

      providerPlaceId:
        placeProperties?.place_id ??
        null,

      distance:
        placeProperties?.distance ??
        null,
    };
  },
);

/*
 * ============================================================
 * SEARCH LOCATION — GEOAPIFY
 * ============================================================
 */

exports.searchLocation = onCall(
  {
    region: "europe-central2",
    enforceAppCheck: true,
    secrets: [
      GEOAPIFY_API_KEY,
    ],
  },
  async (request) => {
    requireAnonymousUser(request);

    const rawQuery =
      request.data?.query;

    if (typeof rawQuery !== "string") {
      throw new HttpsError(
        "invalid-argument",
        "Brak tekstu wyszukiwania.",
      );
    }

    const query =
      rawQuery.trim();

    if (
      query.length < 3 ||
      query.length > 120
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Wyszukiwana fraza musi mieć od 3 do 120 znaków.",
      );
    }

    const apiKey =
      GEOAPIFY_API_KEY.value();

    const searchUrl =
      "https://api.geoapify.com/v1/geocode/search" +
      `?text=${encodeURIComponent(query)}` +
      "&format=json" +
      "&filter=countrycode:pl" +
      "&lang=pl" +
      "&limit=8" +
      `&apiKey=${encodeURIComponent(apiKey)}`;

    let response;

    try {
      response =
        await fetch(searchUrl);
    } catch (error) {
      console.error(
        "Geoapify Search network error:",
        error,
      );

      throw new HttpsError(
        "internal",
        "Nie udało się połączyć z usługą wyszukiwania lokalizacji.",
      );
    }

    if (!response.ok) {
      console.error(
        "Geoapify Search error:",
        response.status,
        await response.text(),
      );

      throw new HttpsError(
        "internal",
        "Nie udało się wyszukać lokalizacji.",
      );
    }

    const data =
      await response.json();

    const rawResults =
      Array.isArray(data?.results)
        ? data.results
        : [];

    const results =
      rawResults
        .filter(
          (result) =>
            typeof result?.lat === "number" &&
            typeof result?.lon === "number",
        )
        .map(
          (result) => ({
            name:
              result.name ??
              result.city ??
              result.street ??
              result.formatted ??
              query,

            formatted:
              result.formatted ??
              null,

            lat:
              result.lat,

            lng:
              result.lon,

            resultType:
              result.result_type ??
              null,

            city:
              result.city ??
              result.town ??
              result.village ??
              null,

            postcode:
              result.postcode ??
              null,

            placeId:
              result.place_id ??
              null,
          }),
        );

    return {
      results,
      count: results.length,
    };
  },
);