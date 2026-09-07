import { defineRailway, github, preserve, project, service, volume } from "railway/iac";

export default defineRailway(() => {
  const state = volume("worker-state", { region: "us-east4-eqdc4a", sizeMB: 1024 });
  const worker = service("worker", {
    source: github("carterDWatts/personal_assistant", { branch: "design" }),
    build: { builder: "DOCKERFILE", dockerfilePath: "Dockerfile" },
    replicas: { "us-east4": 1 },
    deploy: {
      sleepApplication: false,
      restartPolicyType: "ALWAYS",
      drainingSeconds: 20,
      limitOverride: { containers: { cpu: 1, memoryBytes: 4 * 1024 ** 3 } },
    },
    volumeMounts: { "/data": state },
    env: {
      ASSISTANT_RUNTIME: "codex",
      ASSISTANT_OPENAI_MODEL: "gpt-5.5",
      ASSISTANT_EFFORT: "low",
      ASSISTANT_TIMEZONE: "America/Los_Angeles",
      ASSISTANT_DATABASE_URL: preserve(),
      ASSISTANT_CODEX_AUTH_JSON: preserve(),
      CLAUDE_CODE_OAUTH_TOKEN: preserve(),
    },
  });

  return project("personal-assistant", { resources: [worker, state] });
});
