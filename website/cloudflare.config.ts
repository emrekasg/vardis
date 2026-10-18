import { defineConfig } from "cf/config";

// vardis.app is a static site: no Worker code, no request logs, no analytics.
export default defineConfig({
  worker: {
    name: "vardis",
    compatibilityDate: "2026-09-25",
    observability: { enabled: false },
    assets: {
      htmlHandling: "auto-trailing-slash",
      notFoundHandling: "404-page",
    },
    domains: ["vardis.app", "www.vardis.app"],
  },
});
