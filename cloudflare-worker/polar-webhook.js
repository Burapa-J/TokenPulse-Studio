/**
 * Zero-Cost Cloudflare Worker for Polar.sh / Lemon Squeezy Webhook License Fulfillment
 * Generates the exact same deterministic TPPRO-<HEX>-<HMAC> license key verified offline by TokenPulseCore.
 */
export default {
  async fetch(request) {
    if (request.method !== "POST") {
      return new Response("TokenPulse License Webhook Active", { status: 200 });
    }
    const payload = await request.json();
    const rawEmail = (
      payload?.data?.customer?.email ||
      payload?.data?.attributes?.user_email ||
      payload?.email ||
      ""
    ).trim().toLowerCase();

    if (!rawEmail || !rawEmail.includes("@")) {
      return new Response(JSON.stringify({ error: "Missing customer email" }), { status: 400 });
    }

    const licenseKey = await generateTokenPulseKey(rawEmail);
    return new Response(
      JSON.stringify({
        product: "TokenPulse Studio Pro",
        email: rawEmail,
        licenseKey
      }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  }
};

async function generateTokenPulseKey(normalizedEmail) {
  const enc = new TextEncoder();
  const digestBuf = await crypto.subtle.digest("SHA-256", enc.encode(normalizedEmail));
  const payloadHex = Array.from(new Uint8Array(digestBuf).slice(0, 4))
    .map((b) => b.toString(16).padStart(2, "0").toUpperCase())
    .join("");

  const keyMaterial = await crypto.subtle.importKey(
    "raw",
    enc.encode("TokenPulse-PolarMoR-2026-v1"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sigBuf = await crypto.subtle.sign(
    "HMAC",
    keyMaterial,
    enc.encode(`${payloadHex}:${normalizedEmail}`)
  );
  const sigHex = Array.from(new Uint8Array(sigBuf).slice(0, 4))
    .map((b) => b.toString(16).padStart(2, "0").toUpperCase())
    .join("");

  return `TPPRO-${payloadHex}-${sigHex}`;
}
