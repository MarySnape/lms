import type { Config } from "tailwindcss";

const config = {
  content: ["./src/**/*.{ts,tsx}"],
  darkMode: ["class"],
  theme: { extend: {} },
  plugins: [],
} satisfies Config;

export default config;
