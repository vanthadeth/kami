import Image from "next/image";
import { ProgressBar } from "@/components/ui";

// Shown while a page loads, for example right after Google sends you back.
export default function Loading() {
  return (
    <main className="kami-fade flex min-h-dvh flex-col items-center justify-center gap-4 bg-[#0F2A44]" aria-busy="true">
      <ProgressBar />
      <Image src="/icons/icon.svg" alt="" width={72} height={72} className="kami-pulse" priority />
      <p role="status" className="text-sm text-[#C5D1DD]">Loading…</p>
    </main>
  );
}
