import Image from "next/image";
import { signInWithGoogle } from "./actions";

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const { error } = await searchParams;
  return (
    <main className="mx-auto flex min-h-dvh max-w-sm flex-col items-center justify-center gap-6 px-4 text-center">
      <Image src="/icons/icon.svg" alt="KAMI" width={80} height={80} priority />
      <h1 className="text-2xl font-bold">Sign in to KAMI</h1>
      {error && (
        <p role="alert" className="rounded-lg bg-red-50 px-4 py-2 text-sm text-red-700">
          Sign-in did not work. Please try again.
        </p>
      )}
      <form action={signInWithGoogle} className="w-full">
        <button
          type="submit"
          className="h-12 w-full rounded-xl bg-[#0F2A44] px-4 text-base font-semibold text-white focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#00A8FF]"
        >
          Continue with Google
        </button>
      </form>
      <p className="text-sm text-[#4A5D70]">Facebook and Telegram come later.</p>
    </main>
  );
}
