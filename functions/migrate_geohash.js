const { initializeApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");
const { geohashForLocation } = require("geofire-common");

initializeApp({
  projectId: "darmowakranowka",
});

async function run() {
  const db = getFirestore();

  const snapshot = await db
    .collection("places")
    .get();

  let updated = 0;
  let skipped = 0;

  for (const doc of snapshot.docs) {
    const data = doc.data();
    const location = data.location;

    if (!location) {
      console.log(`SKIP ${doc.id}: brak pola location`);
      skipped++;
      continue;
    }

    const latitude = location.latitude;
    const longitude = location.longitude;

    if (
      typeof latitude !== "number" ||
      typeof longitude !== "number"
    ) {
      console.log(
        `SKIP ${doc.id}: nieprawidłowa lokalizacja`,
      );
      skipped++;
      continue;
    }

    const geohash = geohashForLocation([
      latitude,
      longitude,
    ]);

    await doc.ref.update({
      lat: latitude,
      lng: longitude,
      geohash,
    });

    console.log(
      `UPDATED ${doc.id}: ${geohash}`,
    );

    updated++;
  }

  console.log("");
  console.log("Migracja zakończona.");
  console.log(`Updated: ${updated}`);
  console.log(`Skipped: ${skipped}`);
}

run()
  .then(() => {
    process.exit(0);
  })
  .catch((error) => {
    console.error("Błąd migracji:");
    console.error(error);
    process.exit(1);
  });