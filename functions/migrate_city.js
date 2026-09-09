const admin = require("firebase-admin");

admin.initializeApp();

const db = admin.firestore();

function cleanText(value) {
  return String(value ?? "")
    .replace(/\s+/g, " ")
    .trim();
}

const CITY_ALIASES = new Map([
  ["warsaw", "Warszawa"],
  ["warszawa", "Warszawa"],

  ["gdansk", "Gdańsk"],
  ["gdańsk", "Gdańsk"],

  ["poznan", "Poznań"],
  ["poznań", "Poznań"],

  ["krakow", "Kraków"],
  ["kraków", "Kraków"],

  ["bialystok", "Białystok"],
  ["białystok", "Białystok"],

  ["bielsko-biala", "Bielsko-Biała"],
  ["bielsko-biała", "Bielsko-Biała"],

  ["lodz", "Łódź"],
  ["łódź", "Łódź"],

  ["wroclaw", "Wrocław"],
  ["wrocław", "Wrocław"],

  ["rzeszow", "Rzeszów"],
  ["rzeszów", "Rzeszów"],

  ["torun", "Toruń"],
  ["toruń", "Toruń"],

  ["olsztyn", "Olsztyn"],
  ["szczecin", "Szczecin"],
  ["lublin", "Lublin"],
  ["katowice", "Katowice"],
  ["gdynia", "Gdynia"],
  ["sopot", "Sopot"],
]);

function normalizeCity(city) {
  let result = cleanText(city);

  if (!result) {
    return null;
  }

  result = result
    .replace(/^\d{2}-\d{3}\s+/, "")
    .trim();

  if (!result) {
    return null;
  }

  const lower = result.toLowerCase();

  if (
    lower === "polska" ||
    lower === "poland"
  ) {
    return null;
  }

  const alias = CITY_ALIASES.get(lower);

  if (alias) {
    return alias;
  }

  return result;
}

function detectCityFromAddress(address) {
  const value = cleanText(address);

  if (!value) {
    return null;
  }

  const parts = value
    .split(",")
    .map((part) => cleanText(part))
    .filter(Boolean);

  if (parts.length === 0) {
    return null;
  }

  while (
    parts.length > 0 &&
    ["polska", "poland"].includes(
      parts[parts.length - 1].toLowerCase()
    )
  ) {
    parts.pop();
  }

  if (parts.length === 0) {
    return null;
  }

  for (let i = parts.length - 1; i >= 0; i--) {
    const match = parts[i].match(
      /^\d{2}-\d{3}\s+(.+)$/
    );

    if (match) {
      return normalizeCity(match[1]);
    }
  }

  if (parts.length >= 2) {
    return normalizeCity(
      parts[parts.length - 1]
    );
  }

  return null;
}

function cityToSlug(city) {
  return city
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/ł/g, "l")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

async function commitBatch(operations) {
  if (operations.length === 0) {
    return;
  }

  const batch = db.batch();

  for (const operation of operations) {
    batch.update(
      operation.ref,
      {
        city: operation.city,
        citySlug: operation.citySlug,
      }
    );
  }

  await batch.commit();
}

async function main() {
  console.log("");
  console.log("======================================");
  console.log("CITY MIGRATION — WRITE MODE");
  console.log("ZAPISUJĘ city + citySlug");
  console.log("======================================");
  console.log("");

  const snapshot = await db
    .collection("places")
    .get();

  console.log(
    `Liczba dokumentów places: ${snapshot.size}`
  );
  console.log("");

  let updatedCount = 0;
  let alreadyCompleteCount = 0;
  let missingAddressCount = 0;
  let undetectedCount = 0;

  const operations = [];

  for (const doc of snapshot.docs) {
    const data = doc.data();

    const address = cleanText(data.address);
    const existingCity = cleanText(data.city);
    const existingCitySlug = cleanText(data.citySlug);

    if (
      existingCity &&
      existingCitySlug
    ) {
      alreadyCompleteCount++;

      console.log(
        `[SKIP] ${doc.id}`
      );
      console.log(
        `  city:     ${existingCity}`
      );
      console.log(
        `  citySlug: ${existingCitySlug}`
      );
      console.log("");

      continue;
    }

    if (!address) {
      missingAddressCount++;

      console.log(
        `[NO ADDRESS] ${doc.id}`
      );
      console.log("");

      continue;
    }

    const city =
      detectCityFromAddress(address);

    if (!city) {
      undetectedCount++;

      console.log(
        `[UNDETECTED] ${doc.id}`
      );
      console.log(
        `  address: ${address}`
      );
      console.log("");

      continue;
    }

    const citySlug =
      cityToSlug(city);

    operations.push({
      ref: doc.ref,
      city,
      citySlug,
    });

    console.log(
      `[WRITE] ${doc.id}`
    );
    console.log(
      `  address:  ${address}`
    );
    console.log(
      `  city:     ${city}`
    );
    console.log(
      `  citySlug: ${citySlug}`
    );
    console.log("");
  }

  const batchSize = 400;

  for (
    let i = 0;
    i < operations.length;
    i += batchSize
  ) {
    const chunk = operations.slice(
      i,
      i + batchSize
    );

    await commitBatch(chunk);

    updatedCount += chunk.length;

    console.log(
      `Zapisano batch: ${chunk.length} dokumentów`
    );
  }

  console.log("");
  console.log("======================================");
  console.log("PODSUMOWANIE");
  console.log("======================================");

  console.log(
    `Wszystkie dokumenty:       ${snapshot.size}`
  );

  console.log(
    `Zaktualizowano:             ${updatedCount}`
  );

  console.log(
    `Już miały city + slug:      ${alreadyCompleteCount}`
  );

  console.log(
    `Brak address:               ${missingAddressCount}`
  );

  console.log(
    `Nie rozpoznano city:        ${undetectedCount}`
  );

  console.log("");
  console.log(
    "Migracja zakończona."
  );
  console.log("");
}

main()
  .then(() => {
    process.exit(0);
  })
  .catch((error) => {
    console.error("");
    console.error(
      "Błąd podczas migracji:"
    );
    console.error(error);
    console.error("");

    process.exit(1);
  });