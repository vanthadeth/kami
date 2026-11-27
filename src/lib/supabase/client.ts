import { createBrowserClient } from "@supabase/ssr";

// Browser client. Uses only the public (publishable) key; row level security does the protecting.
export function createClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
  );
}
