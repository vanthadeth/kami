"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

// First sign-in to the console: link an authenticator app, then confirm with a 6-digit code.
export default function SetupTwoFactor() {
  const router = useRouter();
  const supabase = useRef(createClient()).current;
  const [factorId, setFactorId] = useState<string | null>(null);
  const [qr, setQr] = useState<string | null>(null);
  const [secret, setSecret] = useState<string | null>(null);
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const started = useRef(false);

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    (async () => {
      // Remove an unfinished earlier attempt so setup can be repeated.
      const { data: list } = await supabase.auth.mfa.listFactors();
      for (const f of list?.all ?? []) {
        if (f.factor_type === "totp" && f.status === "unverified") await supabase.auth.mfa.unenroll({ factorId: f.id });
      }
      const { data, error } = await supabase.auth.mfa.enroll({ factorType: "totp", friendlyName: "KAMI console" });
      if (error || !data) return setError("Could not start two-factor setup. Please reload.");
      setFactorId(data.id);
      setQr(data.totp.qr_code);
      setSecret(data.totp.secret);
    })();
  }, [supabase]);

  async function confirm(e: React.FormEvent) {
    e.preventDefault();
    if (!factorId) return;
    setBusy(true);
    setError(null);
    const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId, code: code.trim() });
    setBusy(false);
    if (error) return setError("That code did not work. Check the code and try again.");
    router.replace("/platform");
    router.refresh();
  }

  return (
    <main className="mx-auto flex min-h-dvh max-w-sm flex-col justify-center gap-5 px-4 py-8">
      <h1 className="text-2xl font-bold">Set up two-factor</h1>
      <p className="text-[#4A5D70]">The console needs a code from an authenticator app every time you sign in.</p>
      <ol className="list-decimal pl-5 text-sm leading-6 text-[#0F2A44]">
        <li>Open an authenticator app (Google Authenticator, Microsoft Authenticator or similar).</li>
        <li>Scan this code, or type the key by hand.</li>
        <li>Enter the 6-digit code the app shows.</li>
      </ol>
      {qr ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={qr} alt="Two-factor QR code" width={200} height={200} className="self-center rounded-xl bg-white p-2" />
      ) : (
        <p className="self-center text-sm text-[#4A5D70]">Preparing your code…</p>
      )}
      {secret && (
        <p className="break-all text-center text-xs text-[#4A5D70]">
          Key: <code className="select-all font-mono">{secret}</code>
        </p>
      )}
      <form onSubmit={confirm} className="flex flex-col gap-3">
        <label htmlFor="code" className="text-sm font-semibold">6-digit code</label>
        <input
          id="code" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6}
          value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
          className="h-12 rounded-xl border border-[#B8C6D3] bg-white px-3 text-center text-xl tracking-widest"
        />
        {error && <p role="alert" className="text-sm text-red-700">{error}</p>}
        <button type="submit" disabled={busy || code.length !== 6 || !factorId}
          className="h-12 rounded-xl bg-[#0F2A44] text-base font-semibold text-white disabled:opacity-50 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#00A8FF]">
          {busy ? "Checking…" : "Turn on two-factor"}
        </button>
      </form>
    </main>
  );
}
