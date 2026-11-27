"use client";

import { useState } from "react";
import { useFormStatus } from "react-dom";
import { LiveStatus, ProgressBar, Spinner } from "@/components/ui";

// "Continue with Google". While the server prepares the Google address and the browser
// travels there, the button shows a spinner and cannot be pressed twice.
function Inner({ started }: { started: boolean }) {
  const { pending } = useFormStatus();
  const busy = pending || started;
  return (
    <>
      {busy && <ProgressBar />}
      <LiveStatus>{busy ? "Opening Google, please wait." : ""}</LiveStatus>
      <button
        type="submit"
        disabled={busy}
        aria-busy={busy}
        className="flex h-[52px] w-full items-center justify-center gap-3 rounded-[14px] border border-[#D9E1E8] bg-white px-4 text-base font-semibold text-[#0B1F33] enabled:hover:bg-[#F4F7FA] disabled:cursor-wait disabled:bg-[#F4F7FA] focus-visible:outline focus-visible:outline-[3px] focus-visible:outline-offset-2 focus-visible:outline-[#00A8FF]"
      >
        {busy ? (
          <>
            <Spinner className="text-[#0F2A44]" />
            <span>Opening Google…</span>
          </>
        ) : (
          <>
            <span aria-hidden="true" className="flex h-7 w-7 items-center justify-center rounded-full bg-[#F1F3F4] text-[15px] font-bold text-[#4285F4]">G</span>
            <span>Continue with Google</span>
          </>
        )}
      </button>
    </>
  );
}

export function GoogleButton({ action }: { action: () => Promise<void> }) {
  // Stays true after the click: the page is about to be replaced, so there is nothing to reset.
  const [started, setStarted] = useState(false);
  return (
    <form action={action} onSubmit={() => setStarted(true)} className="w-full">
      <Inner started={started} />
    </form>
  );
}
