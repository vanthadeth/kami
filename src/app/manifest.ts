import type { MetadataRoute } from "next";

export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "KAMI",
    short_name: "KAMI",
    description: "Manage your business in one place.",
    start_url: "/",
    display: "standalone",
    background_color: "#F5F7FA",
    theme_color: "#0F2A44",
    icons: [{ src: "/icons/icon.svg", sizes: "any", type: "image/svg+xml", purpose: "any" }],
  };
}
