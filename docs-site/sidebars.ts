import type { SidebarsConfig } from "@docusaurus/plugin-content-docs";

const sidebars: SidebarsConfig = {
  docsSidebar: [
    {
      type: "category",
      label: "Scanner",
      collapsed: false,
      items: [
        {
          type: "doc",
          id: "scanner-introduction",
          label: "Introduction",
        },
        {
          type: "category",
          label: "Getting Started",
          items: [
            "getting-started/quick-start",
            "getting-started/first-scan",
            "getting-started/featured-vulnerabilities",
          ],
        },
        {
          type: "category",
          label: "User Guide",
          items: [
            "user-guide/core-concepts",
            "user-guide/targets",
            "user-guide/scanning",
            "user-guide/reports",
            "user-guide/probes",
            "user-guide/environment-variables",
            "user-guide/integrations",
            "user-guide/mock-llm",
          ],
        },
        {
          type: "category",
          label: "Deployment",
          items: [
            "deployment/docker-compose",
            "deployment/reverse-proxy",
            "deployment/database",
            "deployment/upgrading",
          ],
        },
        {
          type: "category",
          label: "Development",
          items: [
            "development/setup",
            "development/testing",
            "development/architecture",
            "development/extension-points",
            "development/engines",
            "development/monitoring",
            "development/conventions",
          ],
        },
        {
          type: "doc",
          id: "troubleshooting",
          label: "Troubleshooting",
        },
      ],
    },
    {
      type: "category",
      label: "Jailbreak Feed",
      collapsed: false,
      items: [
        {
          type: "doc",
          id: "jailbreak-feed/introduction",
          label: "Introduction",
        },
        "jailbreak-feed/dashboard",
        {
          type: "category",
          label: "Reports",
          link: { type: "doc", id: "jailbreak-feed/reports/index" },
          items: [
            "jailbreak-feed/reports/overview",
            "jailbreak-feed/reports/taxonomies",
            "jailbreak-feed/reports/prompts-responses",
            "jailbreak-feed/reports/variant-prompts",
            "jailbreak-feed/reports/signature",
          ],
        },
        "jailbreak-feed/probes",
        "jailbreak-feed/system-prompts",
        "jailbreak-feed/api",
        "jailbreak-feed/export",
      ],
    },
  ],
};

export default sidebars;
