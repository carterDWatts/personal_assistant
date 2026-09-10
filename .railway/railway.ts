import { defineRailway, github, preserve, project, service, volume } from "railway/iac";

export default defineRailway(() => {
  const state = volume("worker-state", { region: "us-east4-eqdc4a", sizeMB: 1024 });
  const worker = service("worker", {
    source: github("carterDWatts/personal_assistant", { branch: "main" }),
    build: { builder: "DOCKERFILE", dockerfilePath: "Dockerfile",
      watchPatterns: ["/.dockerignore", "/shared/integrations.json", "/Dockerfile", "/requirements-host.txt", "/engine/**", "/prompts/**", "/identity.json", "/scripts/host-entry.py", "/deploy/**"] },
    replicas: { "us-east4": 1 },
    deploy: {
      sleepApplication: false,
      restartPolicyType: "ALWAYS",
      drainingSeconds: 20,
      limitOverride: { containers: { cpu: 2, memoryBytes: 4 * 1024 ** 3 } },
    },
    volumeMounts: { "/data": state },
    env: {
      ASSISTANT_RUNTIME: "codex",
      ASSISTANT_DEVELOPER_OWNER: preserve(),
      ASSISTANT_DEVELOPER_PROJECT: preserve(),
      ASSISTANT_DEVELOPER_REPO: preserve(),
      ASSISTANT_DEVELOPMENT_REVIEW: preserve(),
      ASSISTANT_DEVELOPMENT_AUTOSHIP: preserve(),
      ASSISTANT_OPENAI_MODEL: "gpt-5.5",
      ASSISTANT_EFFORT: "low",
      ASSISTANT_TIMEZONE: "America/Los_Angeles",
      ASSISTANT_DATABASE_URL: preserve(),
      ASSISTANT_STORAGE_KEY: preserve(),
      ASSISTANT_CREDENTIAL_KEY: preserve(),
      ASSISTANT_SUPABASE_URL: "https://koauvyfxewczcajnlrfp.supabase.co",
      ASSISTANT_CODEX_AUTH_JSON: preserve(),
      CLAUDE_CODE_OAUTH_TOKEN: preserve(),
      ASSISTANT_APNS_KEY: preserve(),
      ASSISTANT_APNS_KEY_ID: preserve(),
      ASSISTANT_APNS_TEAM_ID: preserve(),
    },
  });

  return project("personal-assistant", { resources: [worker, state] });
});
