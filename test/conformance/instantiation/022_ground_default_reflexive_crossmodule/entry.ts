import { make, type G } from "./lib";

type Payload = { id: string; tags: string[] };

const c = make<Payload>();
const x: G<Payload> = c; // ok — reflexive: both sides are G<Payload, Payload>
export {};
