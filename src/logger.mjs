const LOG_LEVELS = { debug: 0, info: 1, warn: 2, error: 3 };
const LEVEL = LOG_LEVELS[process.env.LOG_LEVEL?.trim().toLowerCase()] ?? LOG_LEVELS.info;

function emit(level, component, message, data) {
  if (LOG_LEVELS[level] < LEVEL) return;
  const entry = {
    ts: new Date().toISOString(),
    level,
    component,
    msg: message,
  };
  if (data !== undefined) entry.data = data;
  const out = level === "error" ? process.stderr : process.stdout;
  try {
    out.write(JSON.stringify(entry) + "\n");
  } catch {
    const safe = String(message).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').replace(/\r/g, '\\r').replace(/\t/g, '\\t');
    out.write(`{"ts":"${entry.ts}","level":"${level}","component":"${component}","msg":"${safe}","serializeError":true}\n`);
  }
}

export function createLogger(component) {
  return {
    debug: (msg, data) => emit("debug", component, msg, data),
    info: (msg, data) => emit("info", component, msg, data),
    warn: (msg, data) => emit("warn", component, msg, data),
    error: (msg, data) => emit("error", component, msg, data),
  };
}
