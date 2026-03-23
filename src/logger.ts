import pino from "pino";

const level = process.env.LOG_LEVEL ?? "info";

export const logger = pino({
  name: "poke-pc",
  level,
  redact: {
    paths: [
      "config.pokeApiKey",
      "config.webhook.token",
      "pokeApiKey",
      "webhookToken"
    ],
    censor: "[REDACTED]"
  },
  ...(process.env.NODE_ENV === "production"
    ? {}
    : {
        transport: {
          target: "pino-pretty",
          options: {
            colorize: true,
            translateTime: "SYS:standard"
          }
        }
      })
});
