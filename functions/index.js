const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");

const { initializeApp } = require("firebase-admin/app");
const {
  getFirestore,
  GeoPoint,
  Timestamp,
} = require("firebase-admin/firestore");

const { geohashForLocation } = require("geofire-common");

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