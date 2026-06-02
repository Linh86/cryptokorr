/**
 * Demo entry — builds the CryptoKorr toolset and prints its shape.
 *
 * Run with Node 22+: `node --experimental-strip-types ./demo.ts`
 *
 * The demo does NOT call the SDK; it only constructs the tool
 * definitions so a fresh reviewer can confirm the shape before
 * wiring them into `generateText` / `streamText`.
 */

import { buildCryptoKorrTools } from "./tools.ts";

function printToolDescription(name: string, description: string): void {
  console.log(`\n[demo]      ${name}.description:`);
  for (const line of description.split(/\.\s+/).filter(Boolean)) {
    console.log(`            ${line.trim()}.`);
  }
}

function main(): void {
  if (!process.env["CRYPTOKORR_API_KEY"]) {
    console.error(
      "[demo]      CRYPTOKORR_API_KEY is not set. Export your workspace API key " +
        "(cb_<...>) before running the demo. The SDK never falls back to a default key.",
    );
    process.exit(1);
  }

  const tools = buildCryptoKorrTools();
  const baseUrl = process.env["CRYPTOKORR_BASE_URL"] ?? "http://localhost:4000";

  console.log("[demo]      CryptoKorr client ready");
  console.log(`            base url   = ${baseUrl}`);
  console.log(`            tools      = ${JSON.stringify(Object.keys(tools))}`);

  printToolDescription("submitTransfer", tools.submitTransfer.description);
  printToolDescription(
    "submitAllocateIdleCapital",
    tools.submitAllocateIdleCapital.description,
  );
  printToolDescription("getDecision", tools.getDecision.description);

  console.log(
    "\n[demo]      Wire the tools into your AI SDK call:\n" +
      "            const result = await generateText({ model, prompt, tools });",
  );
  console.log(
    "[demo]      After a write tool, call getDecision and switch on outcome:\n" +
      "            auto_exec | approval_required (NOT an error) | hold | block",
  );
}

main();
