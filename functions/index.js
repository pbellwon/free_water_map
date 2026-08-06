const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { initializeApp } = require("firebase-admin/app");
const {
  getFirestore,
  GeoPoint,
  Timestamp,
} = require("firebase-admin/firestore");

initializeApp();

const PLACE_LIMIT_24H = 2;
const CONFIRMATION_LIMIT_24H = 2;
const REPORT_LIMIT_24H = 1;

const WINDOW_MS = 24 * 60 * 60 * 1000;

function requireAnonymousUser(request) {
  if (!request.auth) {
    throw new HttpsError(
      "unauthenticated",
      "Użytkownik nie jest uwierzytelniony.",
    );
  }

  const provider =
    request.auth.token?.firebase?.sign_in_provider;

  if (provider !== "anonymous") {
    throw new HttpsError(
      "permission-denied",
      "Nieprawidłowy typ uwierzytelnienia.",
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

  return timestamps.filter((timestamp) => {
    return (
      timestamp &&
      typeof timestamp.toMillis === "function" &&
      timestamp.toMillis() > cutoffMilliseconds
    );
  });
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

// ======================================================
// CREATE PLACE
// Limit: 2 lokale / 24 h / UID
// ======================================================

exports.createPlace = onCall(
  {
    region: "europe-central2",
    enforceAppCheck: true,
  },
  async (request) => {
    const uid = requireAnonymousUser(request);

    const data = request.data ?? {};

    const name =
      typeof data.name === "string"
        ? data.name.trim()
        : "";

    const address =
      typeof data.address === "string"
        ? data.address.trim()
        : "";

    const latitude = data.latitude;
    const longitude = data.longitude;
    const category = data.category;

    if (name.length < 2 || name.length > 120) {
      throw new HttpsError(
        "invalid-argument",
        "Nieprawidłowa nazwa lokalu.",
      );
    }

    if (address.length < 3 || address.length > 200) {
      throw new HttpsError(
        "invalid-argument",
        "Nieprawidłowy adres lokalu.",
      );
    }

    if (
      typeof latitude !== "number" ||
      typeof longitude !== "number" ||
      !Number.isFinite(latitude) ||
      !Number.isFinite(longitude) ||
      latitude < -90 ||
      latitude > 90 ||
      longitude < -180 ||
      longitude > 180
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Nieprawidłowa lokalizacja.",
      );
    }

    const allowedCategories = [
      "restaurant",
      "cafe",
      "bar",
      "other",
    ];

    if (!allowedCategories.includes(category)) {
      throw new HttpsError(
        "invalid-argument",
        "Nieprawidłowa kategoria lokalu.",
      );
    }

    const db = getFirestore();

    const rateLimitRef = db
      .collection("_rateLimits")
      .doc(uid);

    const placeRef = db
      .collection("places")
      .doc();

    const confirmationRef = placeRef
      .collection("userConfirmations")
      .doc(uid);

    const now = Timestamp.now();

    const cutoffMilliseconds =
      now.toMillis() - WINDOW_MS;

    let remaining = 0;

    await db.runTransaction(async (transaction) => {
      const rateSnapshot =
        await transaction.get(rateLimitRef);

      const rateData =
        rateSnapshot.exists
          ? rateSnapshot.data()
          : {};

      const recentPlaceCreates =
        filterLast24Hours(
          rateData.placeCreateTimestamps,
          cutoffMilliseconds,
        );

      if (
        recentPlaceCreates.length >=
        PLACE_LIMIT_24H
      ) {
        throw new HttpsError(
          "resource-exhausted",
          "Osiągnięto limit 2 nowych lokali w ciągu 24 godzin.",
        );
      }

      recentPlaceCreates.push(now);

      remaining =
        PLACE_LIMIT_24H -
        recentPlaceCreates.length;

      transaction.set(
        rateLimitRef,
        {
          placeCreateTimestamps:
            recentPlaceCreates,
          updatedAt: now,
        },
        {
          merge: true,
        },
      );

      transaction.set(
        placeRef,
        {
          name,
          address,
          location: new GeoPoint(
            latitude,
            longitude,
          ),
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
    });

    return {
      success: true,
      placeId: placeRef.id,
      remaining,
    };
  },
);

// ======================================================
// CONFIRM PLACE
// Limit: 2 potwierdzenia / 24 h / UID
// ======================================================

exports.confirmPlace = onCall(
  {
    region: "europe-central2",
    enforceAppCheck: true,
  },
  async (request) => {
    const uid = requireAnonymousUser(request);

    const data = request.data ?? {};

    const placeId =
      typeof data.placeId === "string"
        ? data.placeId.trim()
        : "";

    if (placeId.length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "Brak identyfikatora lokalu.",
      );
    }

    const db = getFirestore();

    const placeRef = db
      .collection("places")
      .doc(placeId);

    const confirmationRef = placeRef
      .collection("userConfirmations")
      .doc(uid);

    const rateLimitRef = db
      .collection("_rateLimits")
      .doc(uid);

    const now = Timestamp.now();

    const cutoffMilliseconds =
      now.toMillis() - WINDOW_MS;

    let remaining = 0;
    let resultingConfirmations = 0;
    let resultingStatus = "";

    await db.runTransaction(async (transaction) => {
      const [
        placeSnapshot,
        confirmationSnapshot,
        rateSnapshot,
      ] = await Promise.all([
        transaction.get(placeRef),
        transaction.get(confirmationRef),
        transaction.get(rateLimitRef),
      ]);

      if (!placeSnapshot.exists) {
        throw new HttpsError(
          "not-found",
          "Lokal nie istnieje.",
        );
      }

      if (confirmationSnapshot.exists) {
        throw new HttpsError(
          "already-exists",
          "Ten lokal został już przez Ciebie potwierdzony.",
        );
      }

      const placeData = placeSnapshot.data();

      const currentStatus = placeData.status;

      const currentConfirmations =
        Number(placeData.confirmations ?? 0);

      if (
        currentStatus !== "pending" &&
        currentStatus !== "confirmed"
      ) {
        throw new HttpsError(
          "failed-precondition",
          "Tego lokalu nie można obecnie potwierdzić.",
        );
      }

      if (
        !Number.isInteger(currentConfirmations) ||
        currentConfirmations < 1
      ) {
        throw new HttpsError(
          "failed-precondition",
          "Nieprawidłowe dane lokalu.",
        );
      }

      const rateData =
        rateSnapshot.exists
          ? rateSnapshot.data()
          : {};

      const recentConfirmations =
        filterLast24Hours(
          rateData.confirmationTimestamps,
          cutoffMilliseconds,
        );

      if (
        recentConfirmations.length >=
        CONFIRMATION_LIMIT_24H
      ) {
        throw new HttpsError(
          "resource-exhausted",
          "Osiągnięto limit 2 potwierdzeń w ciągu 24 godzin.",
        );
      }

      recentConfirmations.push(now);

      remaining =
        CONFIRMATION_LIMIT_24H -
        recentConfirmations.length;

      resultingConfirmations =
        currentConfirmations + 1;

      resultingStatus =
        currentStatus === "pending" &&
        resultingConfirmations >= 2
          ? "confirmed"
          : currentStatus;

      transaction.set(
        rateLimitRef,
        {
          confirmationTimestamps:
            recentConfirmations,
          updatedAt: now,
        },
        {
          merge: true,
        },
      );

      transaction.update(
        placeRef,
        {
          confirmations:
            resultingConfirmations,
          lastConfirmedAt: now,
          status: resultingStatus,
        },
      );

      transaction.set(
        confirmationRef,
        {
          userId: uid,
          createdAt: now,
        },
      );
    });

    return {
      success: true,
      confirmations:
        resultingConfirmations,
      status: resultingStatus,
      remaining,
    };
  },
);

// ======================================================
// REPORT PLACE
// Limit: 1 zgłoszenie / 24 h / UID
// ======================================================

exports.reportPlace = onCall(
  {
    region: "europe-central2",
    enforceAppCheck: true,
  },
  async (request) => {
    const uid = requireAnonymousUser(request);

    const data = request.data ?? {};

    const placeId =
      typeof data.placeId === "string"
        ? data.placeId.trim()
        : "";

    const reason =
      typeof data.reason === "string"
        ? data.reason.trim()
        : "";

    const details =
      typeof data.details === "string"
        ? data.details.trim()
        : "";

    if (placeId.length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "Brak identyfikatora lokalu.",
      );
    }

    if (!isValidReportReason(reason)) {
      throw new HttpsError(
        "invalid-argument",
        "Nieprawidłowy powód zgłoszenia.",
      );
    }

    if (details.length > 500) {
      throw new HttpsError(
        "invalid-argument",
        "Opis zgłoszenia jest zbyt długi.",
      );
    }

    const db = getFirestore();

    const placeRef = db
      .collection("places")
      .doc(placeId);

    const reportRef = placeRef
      .collection("reports")
      .doc(uid);

    const rateLimitRef = db
      .collection("_rateLimits")
      .doc(uid);

    const now = Timestamp.now();

    const cutoffMilliseconds =
      now.toMillis() - WINDOW_MS;

    let remaining = 0;
    let resultingStatus = "";
    let resultingDisputeReason = "";

    await db.runTransaction(async (transaction) => {
      const [
        placeSnapshot,
        reportSnapshot,
        rateSnapshot,
      ] = await Promise.all([
        transaction.get(placeRef),
        transaction.get(reportRef),
        transaction.get(rateLimitRef),
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

      const placeData = placeSnapshot.data();

      const currentStatus = placeData.status;

      if (
        currentStatus !== "pending" &&
        currentStatus !== "confirmed" &&
        currentStatus !== "disputed"
      ) {
        throw new HttpsError(
          "failed-precondition",
          "Tego lokalu nie można obecnie zgłosić.",
        );
      }

      const rateData =
        rateSnapshot.exists
          ? rateSnapshot.data()
          : {};

      const recentReports =
        filterLast24Hours(
          rateData.reportTimestamps,
          cutoffMilliseconds,
        );

      if (
        recentReports.length >=
        REPORT_LIMIT_24H
      ) {
        throw new HttpsError(
          "resource-exhausted",
          "Osiągnięto limit 1 zgłoszenia w ciągu 24 godzin.",
        );
      }

      recentReports.push(now);

      remaining =
        REPORT_LIMIT_24H -
        recentReports.length;

      transaction.set(
        rateLimitRef,
        {
          reportTimestamps:
            recentReports,
          updatedAt: now,
        },
        {
          merge: true,
        },
      );

      /*
       * Pierwsze zgłoszenie kwestionuje lokal.
       *
       * Jeżeli lokal jest już disputed, nie zmieniamy
       * pierwotnego disputeReason — nadal jednak zapisujemy
       * indywidualne zgłoszenie użytkownika.
       */
      if (currentStatus !== "disputed") {
        resultingStatus = "disputed";
        resultingDisputeReason = reason;

        transaction.update(
          placeRef,
          {
            status: "disputed",
            disputeReason: reason,
            disputedAt: now,
          },
        );
      } else {
        resultingStatus = "disputed";

        resultingDisputeReason =
          typeof placeData.disputeReason === "string"
            ? placeData.disputeReason
            : reason;
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
    });

    return {
      success: true,
      status: resultingStatus,
      disputeReason:
        resultingDisputeReason,
      remaining,
    };
  },
);