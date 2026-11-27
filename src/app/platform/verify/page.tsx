"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

// Every console sign-in: enter the current code from the authenticator app.
export default function VerifyTwoFactor() {
  const router = useRouter();
  const supabase = useRef(createClient()).current;
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function verify(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const { data: list } = await supabase.auth.mfa.listFactors();
    const factor = list?.totp?.[0]; // verified authenticator apps only
    if (!factor) {
      setBusy(false);
      return router.replace("/platform/setup");
    }
    const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId: factor.id, code: code.trim() });
    setBusy(false);
    if (error) return setError("That code did not work. Check the code and try again.");
    router.replace("/platform");
    router.refresh();
  }

  return (
    <main className="mx-auto flex min-h-dvh max-w-sm flex-col justify-center gap-5 px-4 py-8">
      <h1 className="text-2xl font-bold">Enter your code</h1>
      <p className="text-[#4A5D70]">Open your authenticator app and enter the 6-digit code for KAMI.</p>
      <form onSubmit={verify} className="flex flex-col gap-3">
        <label htmlFor="code" className="text-sm font-semibold">6-digit code</label>
        <input
          id="code" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} autoFocus
          value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
          className="h-12 rounded-xl border border-[#B8C6D3] bg-white px-3 text-center text-xl tracking-widest"
        />
        {error && <p role="alert" className="text-sm text-red-700">{error}</p>}
        <button type="submit" disabled={busy || code.length !== 6}
          className="h-12 rounded-xl bg-[#0F2A44] text-base font-semibold text-white disabled:opacity-50 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#00A8FF]">
          {busy ? "Checking…" : "Open the console"}
        </button>
      </form>
      <form action="/auth/signout" method="post">
        <button type="submit" className="text-sm text-[#4A5D70] underline">Sign out</button>
      </form>
    </main>
  );
}
