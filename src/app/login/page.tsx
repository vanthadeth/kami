import Image from "next/image";
import { signInWithGoogle } from "./actions";
import { GoogleButton } from "./google-button";

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const { error } = await searchParams;
  return (
    <main className="flex min-h-dvh flex-col bg-[#0F2A44]">
      <div className="kami-enter flex flex-1 flex-col items-center justify-center gap-4 px-6 pb-8 pt-12 text-center">
        <Image src="/icons/icon.svg" alt="KAMI logo" width={112} height={112} priority />
        <div className="text-4xl font-bold tracking-[6px] text-white">KAMI</div>
        <p className="max-w-[280px] text-base leading-6 text-[#C5D1DD]">Run your whole business from one app.</p>
      </div>

      <div className="kami-enter-delay mx-auto flex w-full max-w-md flex-col gap-3 rounded-t-[28px] bg-white px-6 pb-8 pt-7">
        <h1 className="text-[22px] font-bold text-[#0B1F33]">Sign in or create an account</h1>
        <p className="mb-2 text-sm leading-5 text-[#4A5D70]">Use the account you already have. No password to remember.</p>
        {error && (
          <p role="alert" className="kami-fade rounded-xl bg-red-50 px-4 py-3 text-sm text-red-700">
            Sign-in did not work. Please try again.
          </p>
        )}
        <GoogleButton action={signInWithGoogle} />
        <p className="pt-1 text-center text-xs text-[#4A5D70]">Facebook and Telegram come later.</p>
      </div>
    </main>
  );
}
