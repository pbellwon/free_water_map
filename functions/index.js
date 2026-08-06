const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {initializeApp} = require("firebase-admin/app");
const {
  getFirestore,
  GeoPoint,
  Timestamp,
} = require("firebase-admin/firestore");

initializeApp();

const PLACE_LIMIT_24H = 3;
const WINDOW_MS = 24 * 60 * 60 * 1000;

exports.createPlace = onCall(
  {
    region: "europe-central2",
    enforceAppCheck: true,
  },
  async (request) => {
    // 1. Musi istnieć Firebase Auth.
    if (!request.auth) {
      throw new HttpsError(
        "unauthenticated",
        "Użytkownik nie jest uwierzytelniony.",
      );
    }

    // 2. Na MVP akceptujemy wyłącznie anonimowe konto Firebase.
    const provider =
      request.auth.token?.firebase?.sign_in_provider;

    if (provider !== "anonymous") {
      throw new HttpsError(
        "permission-denied",
        "Nieprawidłowy typ uwierzytelnienia.",
      );
    }

    const uid = request.auth.uid;

    // 3. Dane otrzymane z Fluttera.
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

    // 4. Walidacja nazwy.
    if (name.length < 2 || name.length > 120) {
      throw new HttpsError(
        "invalid-argument",
        "Nieprawidłowa nazwa lokalu.",
      );
    }

    // 5. Walidacja adresu.
    if (address.length < 3 || address.length > 200) {
      throw new HttpsError(
        "invalid-argument",
        "Nieprawidłowy adres lokalu.",
      );
    }

    // 6. Walidacja współrzędnych.
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

    // 7. Walidacja kategorii.
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

    /*
     * Jeden dokument rate limitu na UID.
     *
     * Później wykorzystamy ten sam dokument również dla:
     * - confirmationTimestamps
     * - reportTimestamps
     */
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

    /*
     * Transakcja jest ważna:
     *
     * jeśli użytkownik wyśle kilka requestów jednocześnie,
     * wszystkie konkurują o ten sam dokument _rateLimits/{uid}.
     *
     * Firestore ponowi transakcję, jeśli odczytany dokument
     * zmieni się w trakcie operacji.
     */
    await db.runTransaction(async (transaction) => {
      const rateLimitSnapshot =
        await transaction.get(rateLimitRef);

      const rateData =
        rateLimitSnapshot.exists
          ? rateLimitSnapshot.data()
          : {};

      const storedTimestamps =
        Array.isArray(rateData.placeCreateTimestamps)
          ? rateData.placeCreateTimestamps
          : [];

      // Zostawiamy tylko wpisy z ostatnich 24 godzin.
      const recentTimestamps =
        storedTimestamps.filter((timestamp) => {
          return (
            timestamp &&
            typeof timestamp.toMillis === "function" &&
            timestamp.toMillis() >
              cutoffMilliseconds
          );
        });

      // Limit osiągnięty.
      if (recentTimestamps.length >= PLACE_LIMIT_24H) {
        throw new HttpsError(
          "resource-exhausted",
          "Osiągnięto limit 3 nowych lokali w ciągu 24 godzin.",
        );
      }

      recentTimestamps.push(now);

      remaining =
        PLACE_LIMIT_24H -
        recentTimestamps.length;

      // Aktualizacja rate limitu.
      transaction.set(
        rateLimitRef,
        {
          placeCreateTimestamps:
            recentTimestamps,
          updatedAt: now,
        },
        {
          merge: true,
        },
      );

      // Utworzenie lokalu.
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

      // Autor automatycznie daje pierwsze potwierdzenie.
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