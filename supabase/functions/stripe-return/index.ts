import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

// Landing page after Stripe Checkout / Portal. Deploy with --no-verify-jwt.
// The app refreshes billing state when it returns to the foreground.

serve((req) => {
  const state = new URL(req.url).searchParams.get("state");
  const message = state === "success"
    ? "Payment complete."
    : state === "cancel"
    ? "Checkout canceled."
    : "Billing updated.";
  const html = `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Kawenreel</title>
  <style>
    body { font-family: -apple-system, system-ui, sans-serif; display: flex; align-items: center;
           justify-content: center; height: 100vh; margin: 0; background: #111; color: #eee; }
    main { text-align: center; }
    p { color: #999; }
  </style>
</head>
<body>
  <main>
    <h1>${message}</h1>
    <p>Return to Kawenreel — your account updates automatically.</p>
  </main>
</body>
</html>`;
  return new Response(html, { headers: { "Content-Type": "text/html; charset=utf-8" } });
});
