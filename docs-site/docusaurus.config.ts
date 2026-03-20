import { themes as prismThemes } from "prism-react-renderer";
import type { Config } from "@docusaurus/types";
import type * as Preset from "@docusaurus/preset-classic";
import remarkMath from "remark-math";
import rehypeKatex from "rehype-katex";

const config: Config = {
  title: "Scanner",
  tagline: "Open-source AI model security assessment platform",
  favicon: "img/favicon.ico",

  url: "https://0din-ai.github.io",
  baseUrl: "/ai-scanner/",

  organizationName: "0din-ai",
  projectName: "ai-scanner",
  trailingSlash: false,

  onBrokenLinks: "throw",

  stylesheets: [
    {
      href: "https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css",
      type: "text/css",
      crossorigin: "anonymous",
    },
  ],

  i18n: {
    defaultLocale: "en",
    locales: ["en"],
  },

  markdown: {
    mermaid: true,
    hooks: {
      onBrokenMarkdownLinks: "warn",
    },
  },

  themes: ["@docusaurus/theme-mermaid"],

  presets: [
    [
      "classic",
      {
        docs: {
          routeBasePath: "/",
          sidebarPath: "./sidebars.ts",
          editUrl:
            "https://github.com/0din-ai/ai-scanner/tree/main/docs-site/",
          remarkPlugins: [remarkMath],
          rehypePlugins: [rehypeKatex],
        },
        blog: false,
        theme: {
          customCss: "./src/css/custom.css",
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    navbar: {
      title: "Scanner",
      logo: {
        alt: "Scanner Logo",
        src: "img/logo.png",
      },
      items: [
        {
          type: "docSidebar",
          sidebarId: "docsSidebar",
          position: "left",
          label: "Docs",
        },
        {
          href: "https://0din.ai/marketing/scanner",
          label: "Request a Demo",
          position: "right",
        },
        {
          href: "https://github.com/0din-ai/ai-scanner",
          label: "GitHub",
          position: "right",
        },
      ],
    },
    footer: {
      style: "dark",
      links: [
        {
          title: "Docs",
          items: [
            { label: "Getting Started", to: "/getting-started/quick-start" },
            { label: "User Guide", to: "/user-guide/core-concepts" },
            { label: "Deployment", to: "/deployment/docker-compose" },
            { label: "Development", to: "/development/setup" },
          ],
        },
        {
          title: "Community",
          items: [
            {
              label: "GitHub",
              href: "https://github.com/0din-ai/ai-scanner",
            },
            {
              label: "Issues",
              href: "https://github.com/0din-ai/ai-scanner/issues",
            },
          ],
        },
        {
          title: "More",
          items: [
            { label: "0din.ai", href: "https://0din.ai" },
            { label: "NVIDIA garak", href: "https://github.com/NVIDIA/garak" },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} Scanner Contributors. Licensed under Apache 2.0.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ["ruby", "bash", "json", "yaml", "python", "docker"],
    },
    mermaid: {
      theme: { light: "neutral", dark: "forest" },
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
