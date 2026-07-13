import "./a";
import "./b";
const ok: Config = { host: "localhost", port: 8080 };
const missing: Config = { host: "x" };
const p: number = ok.port;
const h: string = ok.host;
const bad: string = ok.port;
