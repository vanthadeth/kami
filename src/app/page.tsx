import Image from "next/image";
import { createClient } from "@/lib/supabase/server";

export default async function Home() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const name = (user?.user_metadata?.full_name as string | undefined) ?? user?.email ?? "there";

  return (
    <main className="mx-auto flex min-h-dvh max-w-sm flex-col items-center justify-center gap-6 px-4 text-center">
      <Image src="/icons/icon.svg" alt="KAMI" width={96} height={96} priority />
      <h1 className="text-3xl font-bold">Welcome, {name}</h1>
      <p className="text-base text-[#4A5D70]">You are signed in to KAMI.</p>
      <form action="/auth/signout" method="post">
        <button
          type="submit"
          className="h-11 rounded-xl border border-[#B8C6D3] bg-white px-5 text-sm font-semibold focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#00A8FF]"
        >
          Sign out
        </button>
      </form>
    </main>
  );
}
