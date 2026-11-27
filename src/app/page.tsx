import Image from "next/image";

export default function Home() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-sm flex-col items-center justify-center gap-6 px-4 text-center">
      <Image src="/icons/icon.svg" alt="KAMI" width={96} height={96} priority />
      <h1 className="text-3xl font-bold">KAMI</h1>
      <p className="text-base text-[#4A5D70]">Manage your business in one place.</p>
      <p className="rounded-full bg-white px-4 py-2 text-sm font-medium shadow-sm">
        Sign-in is coming in the next step.
      </p>
    </main>
  );
}
